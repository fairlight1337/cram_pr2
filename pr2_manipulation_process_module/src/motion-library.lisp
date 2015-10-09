;;; Copyright (c) 2012, Jan Winkler <winkler@informatik.uni-bremen.de>
;;; All rights reserved.
;;; 
;;; Redistribution and use in source and binary forms, with or without
;;; modification, are permitted provided that the following conditions are met:
;;; 
;;;     * Redistributions of source code must retain the above copyright
;;;       notice, this list of conditions and the following disclaimer.
;;;     * Redistributions in binary form must reproduce the above copyright
;;;       notice, this list of conditions and the following disclaimer in the
;;;       documentation and/or other materials provided with the distribution.
;;;     * Neither the name of the Intelligent Autonomous Systems Group/
;;;       Universitaet Bremen nor the names of its contributors may be used to
;;;       endorse or promote products derived from this software without
;;;       specific prior written permission.
;;; 
;;; THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
;;; AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
;;; IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
;;; ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE
;;; LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
;;; CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
;;; SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
;;; INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
;;; CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
;;; ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
;;; POSSIBILITY OF SUCH DAMAGE.

(in-package :pr2-manipulation-process-module)

(defvar *registered-arm-poses* nil)

(defparameter *lift-distance-override* nil)

;; TODO(winkler): This is very hacky; its in here for demo purposes
;; and its gonna be resolved into the parameter sets as soon as the
;; demo is over.
(defvar *raise-elbow* t)

(defclass manipulation-parameters ()
  ((arm :accessor arm :initform nil :initarg :arm)
   (safe-pose :accessor safe-pose :initform nil :initarg :safe-pose)
   (grasp-type :accessor grasp-type :initform nil :initarg :grasp-type)
   (object-part :accessor object-part :initform nil :initarg :object-part)
   (max-collisions-tolerance :accessor max-collisions-tolerance :initform nil :initarg :max-collisions-tolerance)))

(defclass grasp-parameters (manipulation-parameters)
  ((grasp-pose :accessor grasp-pose :initform nil :initarg :grasp-pose)
   (pregrasp-pose :accessor pregrasp-pose :initform nil :initarg :pregrasp-pose)
   (effort :accessor effort :initform nil :initarg :effort)
   (close-radius :accessor close-radius :initform nil :initarg :close-radius)))

(defclass putdown-parameters (manipulation-parameters)
  ((pre-putdown-pose :accessor pre-putdown-pose :initform nil :initarg :pre-putdown-pose)
   (putdown-pose :accessor putdown-pose :initform nil :initarg :putdown-pose)
   (unhand-pose :accessor unhand-pose :initform nil :initarg :unhand-pose)
   (open-radius :accessor open-radius :initform nil :initarg :open-radius)))

(defclass park-parameters (manipulation-parameters)
  ((park-pose :accessor park-pose :initform nil :initarg :park-pose)))

(define-hook on-execute-grasp-with-effort (object-name))
(define-hook on-execute-grasp-gripper-closed
    (object-name gripper-effort gripper-close-pos side pregrasp-pose safe-pose))
(define-hook on-execute-grasp-gripper-positioned-for-grasp
    (object-name gripper-effort gripper-close-pos side pregrasp-pose safe-pose))
(define-hook on-execute-grasp-pregrasp-reached
    (object-name gripper-effort gripper-close-pos side pregrasp-pose safe-pose))
(define-hook cram-language::on-grasp-object (object-name side))
(define-hook cram-language::on-putdown-object (object-name side))

(defun wait-for-gripper-at-position (arm position &key (threshold 0.01))
  (let ((last-state -1))
    (loop as state = (get-gripper-state arm) do
      (roslisp:wait-duration 0.5)
      (format t "HAVE ~a~%" (abs (- last-state state)))
      (when (or (<= (abs (- state position)) threshold) ;; at position
                (<= (abs (- last-state state)) 0.025)) ;; stalled
        (return))
      (setf last-state state))))

(defun wait-for-gripper-state-stalled (side)
  (let ((current-state (get-gripper-state side))
        (threshold 0.05))
    (loop as state = (get-gripper-state side) do
      (sleep 1)
      (cond ((< (abs (- current-state state)) threshold)
             (return t))
            (t (setf current-state state))))))

(defun joint-trajectory-point->joint-state (header joint-names trajectory-point)
  (roslisp:with-fields (positions) trajectory-point
    (roslisp:make-message
     "sensor_msgs/JointState"
     :header header
     :name joint-names
     :position positions)))

(defun arm-pose->trajectory (arm pose &key ignore-collisions raise-elbow ignore-position-check (time-offset 0))
  "Calculated a trajectory from the current pose of gripper `arm' when
trying to assume the pose `pose'."
  (cpl:with-failure-handling
      (((or cram-plan-failures::manipulation-failure
            moveit::moveit-failure) (f)
         (declare (ignore f))
         (ros-error
          (pr2 grasp) "Failed to generate trajectory for ~a." arm)))
    (let ((result (execute-move-arm-pose
                   arm pose
                   :quiet t :plan-only t
                   :ignore-collisions ignore-collisions
                   :raise-elbow raise-elbow
                   :ignore-position-check ignore-position-check)))
      (when result
        (let ((end-time 0))
          (values
           (roslisp:with-fields (joint_trajectory) result
             (roslisp:modify-message-copy
              result
              :joint_trajectory
              (roslisp:with-fields (points)
                  joint_trajectory
                (roslisp:modify-message-copy
                 joint_trajectory
                 :points
                 (map 'vector (lambda (point)
                                (roslisp:with-fields (time_from_start)
                                    point
                                  (let ((time-put (+ time_from_start
                                                     time-offset)))
                                    (when (> time-put end-time)
                                      (setf end-time time-put))
                                    (roslisp:modify-message-copy
                                     point
                                     :time_from_start time-put))))
                      points)))))
           end-time))))))

(defun link-distance-from-pose (link-name pose-stamped)
  (let* ((link-identity-pose (tf:pose->pose-stamped
                              link-name 0.0
                              (tf:make-identity-pose)))
         (link-in-pose-frame (cl-tf2:ensure-pose-stamped-transformed
                              *tf2* link-identity-pose (tf:frame-id pose-stamped)
                              :use-current-ros-time t)))
    (tf:v-dist (tf:origin link-in-pose-frame) (tf:origin pose-stamped))))

(defun pose-assumed (parameter-sets slot-name &key (threshold 3.0))
  "Checks whether the pose defined in the slot `slot-name' was assumes for all parameter sets in `parameter-sets'. The value `threshold' is used as the maximum cartesian distance by which the to be assumed and the actual pose might differ in order to be valid."
  (every #'identity
         (mapcar (lambda (parameter-set)
                   (let* ((link-name (cut:var-value
                                      '?link
                                      (first
                                       (crs:prolog
                                        `(manipulator-link
                                          ,(arm parameter-set) ?link)))))
                          (pose-stamped (slot-value parameter-set slot-name))
                          (distance (link-distance-from-pose link-name pose-stamped)))
                     (<= distance threshold)))
                 (cpl:mapcar-clean (lambda (parameter-set)
                                     (when (slot-value parameter-set slot-name)
                                       parameter-set))
                                   parameter-sets))))

(defun assume-poses (parameter-sets slot-name
                     &key ignore-collisions raise-elbow (catch-control-failures t))
  "Moves all arms defined in `parameter-sets' into the poses given by
the slot `slot-name' as defined in the respective parameter-sets. If
`ignore-collisions' is set, all collisions are ignored during the
motion."
  (ros-info (pr2 motion) "Assuming ~a '~a' pose~a"
            (length parameter-sets) slot-name
            (cond ((= (length parameter-sets) 1) "")
                  (t "s")))
  (let ((max-collisions-tolerance
          (loop for parameter-set in parameter-sets
                as max-collisions-tolerance = (max-collisions-tolerance parameter-set)
                when max-collisions-tolerance
                  maximizing max-collisions-tolerance)))
    (cpl:with-failure-handling
        ((moveit:control-failed (f)
           (declare (ignore f))
           (when catch-control-failures
             (cpl:retry)))
         (cram-plan-failures:manipulation-failure (f)
           (declare (ignore f))
           (when (and max-collisions-tolerance
                      (> max-collisions-tolerance 0))
             (decf max-collisions-tolerance)
             (when (< max-collisions-tolerance 1)
               (setf max-collisions-tolerance nil)
               (setf ignore-collisions t))
             (cpl:retry))))
      (cond ((= (length parameter-sets) 1)
             (when (slot-value (first parameter-sets) slot-name)
               (roslisp:publish
                (roslisp:advertise "/testpose2" "geometry_msgs/PoseStamped")
                (tf:pose-stamped->msg (tf:copy-pose-stamped (slot-value (first parameter-sets) slot-name) :stamp 0.0)))
               (execute-move-arm-pose
                (arm (first parameter-sets))
                (slot-value (first parameter-sets) slot-name)
                :raise-elbow (and raise-elbow
                                  (arm (first parameter-sets)))
                :ignore-collisions ignore-collisions)))
            (t (moveit:execute-trajectories
                (cpl:mapcar-clean
                 (lambda (parameter-set)
                   (when (slot-value parameter-set slot-name)
                     (arm-pose->trajectory
                      (arm parameter-set)
                      (slot-value parameter-set slot-name)
                      :ignore-collisions ignore-collisions
                      :raise-elbow (arm parameter-set))))
                 parameter-sets)
                :ignore-va t)))
      (unless (pose-assumed parameter-sets slot-name)
        (ros-warn (pr2 manip-pm) "Failed to assume at least one pose (distance too large).")
        (cpl:fail 'cram-plan-failures:manipulation-failure)))))

(defmacro with-parameter-sets (parameter-sets &body body)
  "Defines parameter-set specific functions (like assuming poses) for the manipulation parameter sets `parameter-sets' and executes the code `body' in this environment."
  `(labels ((assume-multiple (pose-slot-names)
              (moveit:execute-trajectories
               (loop for pose-slot-name in pose-slot-names
                     with time-offset = 0
                     append (destructuring-bind (pose-slot-name ignore-collisions)
                                pose-slot-name
                              (cpl:mapcar-clean
                               (lambda (parameter-set)
                                 (when (slot-value parameter-set pose-slot-name)
                                   (let ((result (arm-pose->trajectory
                                                  (arm parameter-set)
                                                  (slot-value parameter-set pose-slot-name)
                                                  :ignore-collisions ignore-collisions
                                                  :raise-elbow (arm parameter-set)
                                                  :time-offset (or time-offset 0.0d0))))
                                     (when result
                                       (multiple-value-bind (trajectory time-end) result
                                         (when time-end
                                           (setf time-offset time-end))
                                         trajectory)))))
                               parameter-sets)))
               :ignore-va t))
            (assume (pose-slot-name
                     &optional ignore-collisions raise-elbow)
              (cond ((listp pose-slot-name)
                     (assume-multiple pose-slot-name))
                    (t (assume-poses
                        ,parameter-sets pose-slot-name
                        :ignore-collisions ignore-collisions
                        :raise-elbow raise-elbow
                        :catch-control-failures t)))))
     ,@body))

(defun link-name (arm)
  "Returns the TF link name associated with the wrist of the robot's
arm `arm'."
  (cut:var-value '?link (first (crs:prolog `(manipulator-link ,arm ?link)))))

(defun execute-parks (parameter-sets)
  (with-parameter-sets parameter-sets
    (assume 'park-pose)))

(defun open-gripper-if-necessary (arm &key (threshold 0.08))
  "Opens the gripper on the robot's arm `arm' if its current position
is smaller than `threshold'."
  (when (< (get-gripper-state arm) threshold)
    (open-gripper arm :position threshold)
    (wait-for-gripper-at-position arm threshold)
    (wait-for-gripper-state-stalled arm)))

(defun gripper-closed-p (arm &key (threshold 0.0025))
  "Returns `t' when the robot's gripper on the arm `arm' is smaller
than `threshold'."
  (< (get-gripper-state arm) threshold))

(defun execute-open-drawer (pose handle-pose arm degree)
  ;; TODO(winkler): Implement strategy for opening a drawer here.
  )

(defun execute-open-fridge (pose handle-pose arm degree)
  ;; TODO(winkler): Implement strategy for opening a fridge here.
  )

(defun execute-grasps (object-name parameter-sets)
  "Executes simultaneous grasping of the object given by the name
`object-name'. The grasps (object-relative gripper positions,
grasp-type, effort to use) are defined in the list `parameter-sets'."
  (let ((raise-elbow *raise-elbow*))
    (with-parameter-sets parameter-sets
      (cpl:with-failure-handling
          (((or cram-plan-failures:manipulation-failure
                cram-plan-failures:object-lost) (f)
             (declare (ignore f))
             (ros-warn (pr2 manip-pm) "Falling back to safe pose")
             (assume 'safe-pose t raise-elbow)))
        (assume 'pregrasp-pose nil raise-elbow)
        (cpl:par-loop (parameter-set parameter-sets)
          (open-gripper-if-necessary (arm parameter-set)))
        (cpl:with-failure-handling
            (((or cram-plan-failures:manipulation-failure
                  cram-plan-failures:object-lost) (f)
               (declare (ignore f))
               (ros-warn (pr2 manip-pm)
                         "Falling back to pregrasp pose")
               (assume 'pregrasp-pose nil raise-elbow)))
          (moveit:without-collision-object object-name
            (assume 'grasp-pose t raise-elbow)
            (loop for parameter-set in parameter-sets do
              (ros-info (pr2 manip-pm) "Closing gripper for arm ~a~%"
                        (arm parameter-set))
              (cram-language::on-grasp-object object-name (arm parameter-set))
              (close-gripper (arm parameter-set)
                             :max-effort (effort parameter-set))
              (wait-for-gripper-at-position (arm parameter-set) 0.0)
              (format t "Sleep after closing gripper (converging..) ~a~%" (roslisp:ros-time))
              (roslisp:wait-duration 5))
            (unless (every #'not (mapcar
                                  (lambda (parameter-set)
                                    (gripper-closed-p (arm parameter-set)))
                                  parameter-sets))
              (ros-warn (pr2 manip-pm) "At least one gripper failed to grasp the object")
              (loop for parameter-set in parameter-sets do
                (open-gripper-if-necessary (arm parameter-set)))
              (cpl:fail 'cram-plan-failures:object-lost)))
          (dolist (parameter-set parameter-sets)
            (moveit:attach-collision-object-to-link
             object-name (link-name (arm parameter-set)))))))))

(defun execute-putdowns (object-name parameter-sets)
  "Executes simultaneous putting down of the object in hand given by
the name `object-name'. The current grasps (object-relative gripper
positions, grasp-type, effort to use) are defined in the list
`parameter-sets'."
  (with-parameter-sets parameter-sets
    (cpl:with-failure-handling
        (((or cram-plan-failures:manipulation-failure
              cram-plan-failures:manipulation-pose-unreachable) (f)
           (declare (ignore f))
           (assume 'safe-pose t)
           (cpl:fail 'cram-plan-failures:manipulation-pose-unreachable)))
      (assume 'pre-putdown-pose)
      (cpl:with-failure-handling
          (((or cram-plan-failures:manipulation-failure
                cram-plan-failures:manipulation-pose-unreachable) (f)
             (declare (ignore f))
             (assume 'pre-putdown-pose)
             (cpl:fail 'cram-plan-failures:manipulation-pose-unreachable)))
        (assume 'putdown-pose)
        (dolist (param-set parameter-sets)
          (cram-language::on-putdown-object object-name (arm param-set))
          (open-gripper (arm param-set))
          (wait-for-gripper-state-stalled (arm param-set))
          ;;(sleep 10)
          )
        (block unhand
          (cpl:with-failure-handling
              ((cram-plan-failures:manipulation-failure (f)
                 (declare (ignore f))
                 (assume 'safe-pose t)
                 (return-from unhand)))
            (assume 'unhand-pose))))))
  (dolist (param-set parameter-sets)
    (moveit:detach-collision-object-from-link
     object-name (link-name (arm param-set)))))

(defun execute-linear-motion (sides vector)
  (let* ((global-gripper-poses
           (mapcar (lambda (side)
                     (cons
                      side
                      (cl-tf2:ensure-pose-stamped-transformed
                       *tf2*
                       (cl-tf:pose->pose-stamped
                        (case side
                          (:left "l_wrist_roll_link")
                          (:right "r_wrist_roll_link"))
                        0.0
                        (cl-transforms:make-identity-pose))
                       "map")))
                  sides))
         (translated-gripper-poses
           (mapcar (lambda (global-gripper-pose)
                     (let ((pose (cdr global-gripper-pose))
                           (side (car global-gripper-pose)))
                       (cons
                        side
                        (cl-tf:copy-pose-stamped
                         pose
                         :origin (cl-tf:v+
                                  vector
                                  (cl-transforms:origin pose))))))
                   global-gripper-poses)))
    (moveit:execute-trajectories
     (mapcar (lambda (target-arm-pose)
               (destructuring-bind (arm . pose)
                   target-arm-pose
                 (execute-move-arm-pose
                  arm pose :plan-only t
                           :quiet t
                           :raise-elbow arm
                           :ignore-collisions t)))
             translated-gripper-poses))))

(defun execute-lift (grasp-assignments distance)
  (let ((target-arm-poses
          (mapcar (lambda (grasp-assignment)
                    (cons (side grasp-assignment)
                          (let ((pose-straight
                                  (cl-tf2:ensure-pose-stamped-transformed
                                   *tf2*
                                   (tf:pose->pose-stamped
                                    (link-name (side grasp-assignment))
                                    0.0
                                    (tf:make-identity-pose))
                                   "base_link")))
                            (tf:copy-pose-stamped
                             pose-straight
                             :origin (tf:v+ (tf:origin pose-straight)
                                            (tf:make-3d-vector 0 0 (or *lift-distance-override*
                                                                       distance)))))))
                  grasp-assignments)))
    (cond ((= (length grasp-assignments) 1)
           (destructuring-bind (arm . pose) (first target-arm-poses)
             (execute-move-arm-pose arm pose :ignore-collisions t)))
          (t
           (moveit:execute-trajectories
            (mapcar (lambda (target-arm-pose)
                      (destructuring-bind (arm . pose)
                          target-arm-pose
                        (execute-move-arm-pose
                         arm pose :plan-only t
                                  :quiet t
                                  ;;:raise-elbow arm
                                  :ignore-collisions t)))
                    target-arm-poses))))))

(defun relative-pose (pose pose-offset)
  "Applies the pose `pose-offset' as transformation into the pose
`pose' and returns the result in the frame of `pose'."
  (tf:pose->pose-stamped
   (tf:frame-id pose)
   (ros-time)
   (cl-transforms:transform-pose
    (cl-transforms:pose->transform pose)
    pose-offset)))

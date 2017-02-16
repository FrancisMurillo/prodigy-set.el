;;; prodigy-set.el --- Starting and stopping services together  -*- lexical-binding: t; -*-
;;
;; Filename: prodigy-set.el
;; Description: Starting and stopping together
;; Author: Francis Murillo
;; Maintainer: Francis Murillo
;; Created: Thu Feb 16 20:24:37 2017 (+0800)
;; Version: 0.1
;; Package-Requires: ((emacs "24.4") (prodigy "0.1"))
;; Last-Updated:
;;           By:
;;     Update #: 0
;; URL: https://github.com/FrancisMurillo/prodigy-set
;; Doc URL:
;; Keywords: convenience
;; Compatibility:
;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;
;;; Commentary:
;;
;;
;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;
;;; Change Log:
;;
;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;
;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or (at
;; your option) any later version.
;;
;; This program is distributed in the hope that it will be useful, but
;; WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;; General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs.  If not, see <http://www.gnu.org/licenses/>.
;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;
;;; Code:

(require 'prodigy)
(require 'cl)

(defvar prodigy-set-sets nil
  "An alist of service sets.")

(defconst prodigy-set-executor-prefix "prodigy-set-executor"
  "Prodigy executor prefix.")


(defun* prodigy-set-define-set (&key name executor services &allow-other-keys)
  "Define a service set that will start and stop services."
  (lexical-let ((object
       (list
        :name name
        :executor executor
        :services services)))
    (setq prodigy-set-sets
       (append
        (list object)
        (cl-remove-if ;; Remove same set first
         (lambda (element)
           (equal (plist-get element :name) name))
         prodigy-set-sets)))))

(defun prodigy-set-service-waiting-p (service)
  "Check if SERVICE is waiting."
  (equal (plist-get service :status) prodigy-set-waiting-status))

(defun prodigy-set-service-set-waiting (service)
  "Mark a SERVICE as waiting."
  (prodigy-set-status service prodigy-set-waiting-status))

(defun prodigy-set-subservices (set)
  "Get all subservices of a SET."
  (mapcar
   #'prodigy-find-service
   (mapcar #'car (plist-get set :services))))

(defun prodigy-set-subservice-alist (set)
  "Get all subservice properties of a SET."
  (mapcar
   (lambda (service-pair)
     (pcase-let ((`(,service-name . ,service-properties) service-pair))
       (cons (prodigy-find-service service-name)
          service-properties)))
   (plist-get set :services)))

(defun prodigy-set-subservice-exist-p (set)
  "Check if SET subservices exist"
  (cl-notany #'null (prodigy-set-subservices set)))


(defun prodigy-set-find-set (set-name)
  "Find set that has SET-NAME."
  (cl-find-if
   (lambda (set)
     (equal (plist-get set :name) set-name))
   prodigy-set-sets))

(defun prodigy-set-find-containing-sets (service)
  "Given a SERVICE, return the set(s) it is in."
  (lexical-let ((service-name (plist-get service :name)))
    (cl-remove-if-not
     (lambda (set)
       (lexical-let ((subservices (prodigy-set-subservices set)))
         (cl-some
          (lambda (subservice)
            (equal (plist-get subservice :name) service-name))
          subservices)))
     prodigy-set-sets)))

(defun prodigy-set-find-dependent-sets (service)
  "Given a SERVICE, return the set(s) it is in as well as sets related to it."
  (letrec ((name-test
       (lambda (left right)
         (equal (plist-get left :name)
                (plist-get right :name))))
      (recurser
       (lambda (service initial-sets)
         (lexical-let ((base-sets
              (prodigy-set-find-containing-sets service)))
           (if (null base-sets)
               initial-sets
             (lexical-let* ((base-set-services
                  (apply #'append
                     (mapcar #'prodigy-set-subservices
                             base-sets)))
                 (new-sets
                  (cl-remove-duplicates
                   (apply #'append
                      (mapcar #'prodigy-set-find-containing-sets
                              base-set-services))
                   :test name-test))
                 (unique-sets
                  (cl-set-difference new-sets
                                     initial-sets
                                     :test name-test))
                 (unique-services
                  (cl-remove-duplicates
                   (apply #'append
                      (mapcar #'prodigy-set-subservices
                              unique-sets))
                   :test name-test)))
               (cl-remove-duplicates
                (cl-reduce
                 (lambda (acc service)
                   (funcall recurser service acc))
                 unique-services
                 :initial-value new-sets)
                :test name-test)))))))
    (funcall recurser service (list))))

(defun prodigy-set-executor (set)
  "Find executor for SET."
  (lexical-let* ((executor-symbol (plist-get set :executor))
      (executor-stop-name
       (format "%s--%s"
               prodigy-set-executor-prefix
               (symbol-name executor-symbol))))
    (intern executor-stop-name)))


(defun prodigy-set-executor--parallel-starter (this-subservices callback)
  "Start subservices in parallel.
This needs to be a global function to work with prodigy callbacks"
  (if (null this-subservices)
      (prog1
          (if (functionp callback)
              (funcall callback)
            nil)
        (prodigy-refresh))
    (if (prodigy-service-started-p (car this-subservices))
        (prodigy-set-executor--parallel-starter
         (cdr this-subservices)
         callback)
      (prodigy-start-service (car this-subservices)
                             (lexical-let ((this-subservices this-subservices)
                                 (callback callback))
                               (lambda ()
                                 (prodigy-set-executor--parallel-starter
                                  (cdr this-subservices)
                                  callback)))))))

(defun prodigy-set-executor--parallel-stopper (this-subservices callback)
  "Stop subservices in parallel"
  (if (null this-subservices)
      (prog1
          (if (functionp callback)
              (funcall callback)
            nil)
        (prodigy-refresh))
    (if (not (prodigy-service-started-p (car this-subservices)))
        (prodigy-set-executor--parallel-stopper
         (cdr this-subservices)
         callback)
      (prodigy-stop-service (car this-subservices) t
                            (lexical-let ((this-subservices this-subservices)
                                (callback callback))
                              (lambda ()
                                (prodigy-set-executor--parallel-stopper
                                 (cdr this-subservices)
                                 callback)))))))

(defun prodigy-set-executor--parallel (set service action status callback)
  "Parallel service start executor."
  (lexical-let ((subservices (prodigy-set-subservices set)))
    (pcase action
      ('start
       (prodigy-set-executor--parallel-starter subservices callback))
      ('stop
       (prodigy-set-executor--parallel-stopper subservices callback))
      ('status
       nil))
    nil))


(defconst prodigy-set-waiting-status 'waiting
  "Status for services waiting.")

(prodigy-define-status
  :id prodigy-set-waiting-status
  :face 'prodigy-yellow-face)

(defvar prodigy-set--sequential-state (make-hash-table :test 'equal)
  "State table for the sequential computation.")

(defun prodigy-set-executor--sequential-starter (set this-service-entries callback)
  "Start subservices in sequence."
  (if (null this-service-entries)
      (prog1
          (if (functionp callback)
              (funcall callback)
            nil)
        (prodigy-refresh))
    (pcase-let ((`(,service . ,target-status) (car this-service-entries)))
      (if (prodigy-service-started-p service)
          (prodigy-set-executor--sequential-starter set
                                                    (cdr this-service-entries)
                                                    callback)
        (prodigy-start-service service)
        (lexical-let* ((set set)
            (this-service-entries this-service-entries)
            (callback callback)
            (set-name (plist-get set :name))
            (target-status (or target-status 'ready)))
          (puthash set-name
                   (plist-put (plist-put
                               (gethash set-name prodigy-set--sequential-state)
                               :step-callback
                               (lambda ()
                                 (prodigy-set-executor--sequential-starter
                                  set
                                  (cdr this-service-entries)
                                  callback)))
                              :target-status target-status)
                   prodigy-set--sequential-state))))))

(defun prodigy-set-executor--sequential (set service action status callback)
  "Sequential service start executor."
  (lexical-let ((set-name (plist-get set :name)))
    (when (equal (gethash set-name prodigy-set--sequential-state 'nothing) 'nothing)
      (puthash set-name (list) prodigy-set--sequential-state)))
  (lexical-let* ((set-name (plist-get set :name))
      (this-state (gethash set-name prodigy-set--sequential-state)))
    (pcase action
      ('start
       (puthash set-name (list) prodigy-set--sequential-state)
       (prodigy-set-executor--sequential-starter set
                                                 (prodigy-set-subservice-alist set)
                                                 callback))
      ('stop
       (prodigy-set-executor--parallel set
                                       service
                                       action
                                       status
                                       callback))
      ('status
       (lexical-let ((target-status (plist-get this-state :target-status))
           (step-callback (plist-get this-state :step-callback)))
         (when (equal target-status status)
           (funcall step-callback)))))
    nil))

(defvar prodigy-set--disable-advice nil
  "This flag prevents recursion with the advices.")

(defun prodigy-set-start-service (orig-fun service &optional callback)
  "If a service is started, start it with the rest of them."
  (lexical-let* ((sets (prodigy-set-find-dependent-sets service))
      (callback-counter 0)
      (callback-length (length sets))
      (callback callback)
      (all-callback
       (lambda ()
         (setq callback-counter (1+ callback-counter))
         (if (< callback-counter callback-length)
             nil
           (when (functionp callback)
             (let ((prodigy-set--disable-advice nil))
               (funcall callback)))))))
    (if (null sets)
        (funcall orig-fun service callback)
      (mapc
       (lambda (set)
         (if (or prodigy-set--disable-advice
                (not (prodigy-set-subservice-exist-p set)))
             (funcall orig-fun service callback)
           (lexical-let ((set-executor (prodigy-set-executor set)))
             (let ((prodigy-set--disable-advice t))
               (funcall set-executor set service 'start nil all-callback)))))
       sets))))

(defun prodigy-set-stop-service (orig-fun service &optional force callback)
  "If a service is stop, stop the rest of them."
  (lexical-let* ((sets (prodigy-set-find-dependent-sets service))
      (callback-counter 0)
      (callback-length (length sets))
      (callback callback)
      (all-callback
       (lambda ()
         (setq callback-counter (1+ callback-counter))
         (if (< callback-counter callback-length)
             nil
           (when (functionp callback)
             (let ((prodigy-set--disable-advice nil))
               (funcall callback)))))))
    (if (null sets)
        (funcall orig-fun service force callback)
      (mapc
       (lambda (set)
         (if (or prodigy-set--disable-advice
                (not (prodigy-set-subservice-exist-p set)))
             (funcall orig-fun service force callback)
           (lexical-let ((set-executor (prodigy-set-executor set)))
             (let ((prodigy-set--disable-advice t))
               (funcall set-executor set service 'stop nil all-callback)))))
       sets))))

(defun prodigy-set-change-status (service status)
  "If a service has a status changed, then do something appropriate."
  (lexical-let ((sets (prodigy-set-find-dependent-sets service)))
    (when sets
      (mapc
       (lambda (set)
         (lexical-let ((set-executor (prodigy-set-executor set)))
           (if (or prodigy-set--disable-advice
                  (not (prodigy-set-subservice-exist-p set)))
               nil
             (let ((prodigy-set--disable-advice t))
               (funcall set-executor set service 'status status nil)))))
       sets))))

(define-minor-mode prodigy-set-mode
  "A minor mode to enable prodigy set management."
  :lighter " FnProdigySet"
  :init-value nil
  :global t
  :keymap (make-sparse-keymap)
  (if prodigy-set-mode
      (progn
        (advice-add 'prodigy-start-service :around 'prodigy-set-start-service)
        (advice-add 'prodigy-stop-service :around 'prodigy-set-stop-service)
        (advice-add 'prodigy-set-status :after 'prodigy-set-change-status))
    (progn
      (advice-remove 'prodigy-start-service 'prodigy-set-start-service)
      (advice-remove 'prodigy-stop-service 'prodigy-set-stop-service)
      (advice-remove 'prodigy-set-status 'prodigy-set-change-status))))

(provide 'prodigy-set)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; prodigy-set.el ends here

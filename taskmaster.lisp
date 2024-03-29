;;; -*- Mode: LISP; Syntax: COMMON-LISP; Base: 10 -*-

;;; Copyright (c) 2004-2010, Dr. Edmund Weitz.  All rights reserved.

;;; Redistribution and use in source and binary forms, with or without
;;; modification, are permitted provided that the following conditions
;;; are met:

;;;   * Redistributions of source code must retain the above copyright
;;;     notice, this list of conditions and the following disclaimer.

;;;   * Redistributions in binary form must reproduce the above
;;;     copyright notice, this list of conditions and the following
;;;     disclaimer in the documentation and/or other materials
;;;     provided with the distribution.

;;; THIS SOFTWARE IS PROVIDED BY THE AUTHOR 'AS IS' AND ANY EXPRESSED
;;; OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
;;; WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
;;; ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY
;;; DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
;;; DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE
;;; GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
;;; INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY,
;;; WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
;;; NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
;;; SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

(in-package :hunchentoot)

(defclass taskmaster ()
  ((acceptor :accessor taskmaster-acceptor
             :documentation "A backpointer to the acceptor instance
this taskmaster works for."))
  (:documentation "An instance of this class is responsible for
distributing the work of handling requests for its acceptor.  This is
an \"abstract\" class in the sense that usually only instances of
subclasses of TASKMASTER will be used."))

(defgeneric execute-acceptor (taskmaster)
  (:documentation "This is a callback called by the acceptor once it
has performed all initial processing to start listening for incoming
connections \(see START-LISTENING).  It usually calls the
ACCEPT-CONNECTIONS method of the acceptor, but depending on the
taskmaster instance the method might be called from a new thread."))

(defgeneric handle-incoming-connection (taskmaster socket)
  (:documentation "This function is called by the acceptor to start
processing of requests on a new incoming connection.  SOCKET is the
usocket instance that represents the new connection \(or a socket
handle on LispWorks).  The taskmaster starts processing requests on
the incoming connection by calling the PROCESS-CONNECTION method of
the acceptor instance.  The SOCKET argument is passed to
PROCESS-CONNECTION as an argument."))

(defgeneric shutdown (taskmaster)
  (:documentation "Shuts down the taskmaster, i.e. frees all resources
that were set up by it.  For example, a multi-threaded taskmaster
might terminate all threads that are currently associated with it.
This function is called by the acceptor's STOP method."))

(defgeneric create-request-handler-thread (taskmaster socket)
  (:documentation 
   "Create a new thread in which to process the request.
    This thread will call PROCESS-CONNECTION to process the request."))

(defgeneric too-many-taskmaster-requests (taskmaster socket)
  (:documentation 
   "Signal a \"too many requests\" error, just prior to closing the connection."))

(defgeneric taskmaster-max-thread-count (taskmaster)
  (:documentation
   "The maximum number of request threads this taskmaster will simultaneously
    run before refusing or queueing new connections requests.  If the value
    is null, then there is no limit.")
  (:method ((taskmaster taskmaster))
    "Default method -- no limit on the number of threads."
    nil))

(defgeneric taskmaster-max-accept-count (taskmaster)
  (:documentation
   "The maximum number of connections this taskmaster will accept before refusing
    new connections.  If supplied, this must be greater than MAX-THREAD-COUNT.
    The number of queued requests is the difference between MAX-ACCEPT-COUNT
    and MAX-THREAD-COUNT.")
  (:method ((taskmaster taskmaster))
    "Default method -- no limit on the number of connections."
    nil))

(defgeneric taskmaster-request-count (taskmaster)
  (:documentation
   "Returns the current number of taskmaster requests.")
  (:method ((taskmaster taskmaster))
    "Default method -- claim there is one connection thread."
    1))

(defgeneric increment-taskmaster-request-count (taskmaster)
  (:documentation
   "Atomically increment the number of taskmaster requests.")
  (:method  ((taskmaster taskmaster))
    "Default method -- do nothing."
    nil))

(defgeneric decrement-taskmaster-request-count (taskmaster)
  (:documentation
   "Atomically decrement the number of taskmaster requests")
  (:method ((taskmaster taskmaster))
    "Default method -- do nothing."
    nil))


(defclass single-threaded-taskmaster (taskmaster)
  ()
  (:documentation "A taskmaster that runs synchronously in the thread
where the START function was invoked \(or in the case of LispWorks in
the thread started by COMM:START-UP-SERVER).  This is the simplest
possible taskmaster implementation in that its methods do nothing but
calling their acceptor \"sister\" methods - EXECUTE-ACCEPTOR calls
ACCEPT-CONNECTIONS, HANDLE-INCOMING-CONNECTION calls
PROCESS-CONNECTION."))

(defmethod execute-acceptor ((taskmaster single-threaded-taskmaster))
  ;; in a single-threaded environment we just call ACCEPT-CONNECTIONS
  (accept-connections (taskmaster-acceptor taskmaster)))

(defmethod handle-incoming-connection ((taskmaster single-threaded-taskmaster) socket)
  ;; in a single-threaded environment we just call PROCESS-CONNECTION
  (process-connection (taskmaster-acceptor taskmaster) socket))

(defvar *default-max-thread-count* 100)
(defvar *default-max-accept-count* (+ *default-max-thread-count* 20))

;; You might think it would be nice to provide a taskmaster that takes
;; threads out of a thread pool.  There are two things to consider:
;;  - On a 2010-ish Linux box, thread creation takes less than 250 microseconds.
;;  - Bordeaux Threads doesn't provide a way to "reset" and restart a thread,
;;    and it's not clear how many Lisp implementations can do this.
;; So for now, we leave this out of the mix.
(defclass one-thread-per-connection-taskmaster (taskmaster)
  (#-:lispworks
   (acceptor-process
    :accessor acceptor-process
    :documentation
    "A process that accepts incoming connections and hands them off to new processes
     for request handling.")
   ;; Support for bounding the number of threads we'll create
   (max-thread-count
    :type (or integer null)
    :initarg :max-thread-count
    :initform nil
    :accessor taskmaster-max-thread-count
    :documentation 
    "The maximum number of request threads this taskmaster will simultaneously
     run before refusing or queueing new connections requests.  If the value
     is null, then there is no limit.")
   (max-accept-count
    :type (or integer null)
    :initarg :max-accept-count
    :initform nil
    :accessor taskmaster-max-accept-count
    :documentation
    "The maximum number of connections this taskmaster will accept before refusing
     new connections.  If supplied, this must be greater than MAX-THREAD-COUNT.
     The number of queued requests is the difference between MAX-ACCEPT-COUNT
     and MAX-THREAD-COUNT.")
   (request-count
    :type integer
    :initform 0
    :accessor taskmaster-request-count
    :documentation
    "The number of taskmaster threads currently running.")
   (request-count-lock
    :initform (make-lock "taskmaster-request-count")
    :reader taskmaster-request-count-lock
    :documentation
    "In the absence of 'atomic-incf', we need this to atomically
     increment and decrement the request count.")
   (wait-queue
    :initform (make-condition-variable)
    :reader taskmaster-wait-queue
    :documentation
    "A queue that we use to wait for a free connection.")
   (wait-lock
    :initform (make-lock "taskmaster-thread-lock")
    :reader taskmaster-wait-lock
    :documentation
    "The lock for the connection wait queue.")
   (worker-thread-name-format
    :type (or string null)
    :initarg :worker-thread-name-format
    :initform "hunchentoot-worker-~A"
    :accessor taskmaster-worker-thread-name-format))
  (:default-initargs
   :max-thread-count *default-max-thread-count*
   :max-accept-count *default-max-accept-count*)
  (:documentation "A taskmaster that starts one thread for listening
to incoming requests and one new thread for each incoming connection.

If MAX-THREAD-COUNT is null, a new thread will always be created for
each request.

If MAX-THREAD-COUNT is supplied, the number of request threads is
limited to that.  Furthermore, if MAX-ACCEPT-COUNT is not supplied, an
HTTP 503 will be sent if the thread limit is exceeded.  Otherwise, if
MAX-ACCEPT-COUNT is supplied, it must be greater than MAX-THREAD-COUNT;
in this case, requests are accepted up to MAX-ACCEPT-COUNT, and only
then is HTTP 503 sent.

In a load-balanced environment with multiple Hunchentoot servers, it's
reasonable to provide MAX-THREAD-COUNT but leave MAX-ACCEPT-COUNT null.
This will immediately result in HTTP 503 when one server is out of
resources, so the load balancer can try to find another server.

In an environment with a single Hunchentoot server, it's reasonable
to provide both MAX-THREAD-COUNT and a somewhat larger value for
MAX-ACCEPT-COUNT.  This will cause a server that's almost out of
resources to wait a bit; if the server is completely out of resources,
then the reply will be HTTP 503.

This is the default taskmaster implementation for multi-threaded Lisp
implementations."))

(defmethod initialize-instance :after ((taskmaster one-thread-per-connection-taskmaster) &rest init-args)
  "Ensure the if MAX-ACCEPT-COUNT is supplied, that it is greater than MAX-THREAD-COUNT."
  (declare (ignore init-args))
  (when (taskmaster-max-accept-count taskmaster)
    (unless (taskmaster-max-thread-count taskmaster)
      (parameter-error "MAX-THREAD-COUNT must be supplied if MAX-ACCEPT-COUNT is supplied"))
    (unless (> (taskmaster-max-accept-count taskmaster) (taskmaster-max-thread-count taskmaster))
      (parameter-error "MAX-ACCEPT-COUNT must be greater than MAX-THREAD-COUNT"))))

(defmethod increment-taskmaster-request-count ((taskmaster one-thread-per-connection-taskmaster))
  (when (taskmaster-max-thread-count taskmaster)
    (with-lock-held ((taskmaster-request-count-lock taskmaster))
      (incf (taskmaster-request-count taskmaster)))))

(defmethod decrement-taskmaster-request-count ((taskmaster one-thread-per-connection-taskmaster))
  (when (taskmaster-max-thread-count taskmaster)
    (prog1
        (with-lock-held ((taskmaster-request-count-lock taskmaster))
          (decf (taskmaster-request-count taskmaster)))
      (when (and (taskmaster-max-accept-count taskmaster)
                 (< (taskmaster-request-count taskmaster) (taskmaster-max-accept-count taskmaster)))
        (note-free-connection taskmaster)))))

(defmethod note-free-connection ((taskmaster one-thread-per-connection-taskmaster))
  "Note that a connection has been freed up"
  (with-lock-held ((taskmaster-wait-lock taskmaster))
    (condition-variable-signal (taskmaster-wait-queue taskmaster))))

(defmethod wait-for-free-connection ((taskmaster one-thread-per-connection-taskmaster))
  "Wait for a connection to be freed up"
  (with-lock-held ((taskmaster-wait-lock taskmaster))
    (loop until (< (taskmaster-request-count taskmaster) (taskmaster-max-thread-count taskmaster))
          do (condition-variable-wait (taskmaster-wait-queue taskmaster) (taskmaster-wait-lock taskmaster)))))

(defmethod too-many-taskmaster-requests ((taskmaster one-thread-per-connection-taskmaster) socket)
  (declare (ignore socket))
  (acceptor-log-message (taskmaster-acceptor taskmaster)
                        :warning "Can't handle a new request, too many request threads already"))

;;; usocket implementation

#-:lispworks
(defmethod shutdown ((taskmaster taskmaster))
  taskmaster)

#-:lispworks
(defmethod shutdown ((taskmaster one-thread-per-connection-taskmaster))
  ;; just wait until the acceptor process has finished, then return
  (loop
   (unless (bt:thread-alive-p (acceptor-process taskmaster))
     (return))
   (sleep 1))
  taskmaster)

#-:lispworks
(defmethod execute-acceptor ((taskmaster one-thread-per-connection-taskmaster))
  (setf (acceptor-process taskmaster)
        (bt:make-thread
         (lambda ()
           (accept-connections (taskmaster-acceptor taskmaster)))
         :name (format nil "hunchentoot-listener-~A:~A"
                       (or (acceptor-address (taskmaster-acceptor taskmaster)) "*")
                       (acceptor-port (taskmaster-acceptor taskmaster))))))

#-:lispworks
(defmethod handle-incoming-connection ((taskmaster one-thread-per-connection-taskmaster) socket)
  ;; Here's the idea, with the stipulations given in ONE-THREAD-PER-CONNECTION-TASKMASTER
  ;;  - If MAX-THREAD-COUNT is null, just start a taskmaster
  ;;  - If the connection count will exceed MAX-ACCEPT-COUNT or if MAX-ACCEPT-COUNT
  ;;    is null and the connection count will exceed MAX-THREAD-COUNT,
  ;;    return an HTTP 503 error to the client
  ;;  - Otherwise if we're between MAX-THREAD-COUNT and MAX-ACCEPT-COUNT,
  ;;    wait until the connection count drops, then handle the request
  ;;  - Otherwise, increment REQUEST-COUNT and start a taskmaster
  (cond ((null (taskmaster-max-thread-count taskmaster))
         ;; No limit on number of requests, just start a taskmaster
         (create-request-handler-thread taskmaster socket))
        ((if (taskmaster-max-accept-count taskmaster)
           (>= (taskmaster-request-count taskmaster) (taskmaster-max-accept-count taskmaster))
           (>= (taskmaster-request-count taskmaster) (taskmaster-max-thread-count taskmaster)))
         ;; Send HTTP 503 to indicate that we can't handle the request right now
         (too-many-taskmaster-requests taskmaster socket)
         (send-service-unavailable-reply taskmaster socket))
        ((and (taskmaster-max-accept-count taskmaster)
              (>= (taskmaster-request-count taskmaster) (taskmaster-max-thread-count taskmaster)))
         ;; Wait for a request to finish, then carry on
         (wait-for-free-connection taskmaster)
         (increment-taskmaster-request-count taskmaster)
         (create-request-handler-thread taskmaster socket))
        (t
         ;; We're within both limits, just start a taskmaster
         (increment-taskmaster-request-count taskmaster)
         (create-request-handler-thread taskmaster socket))))

(defun send-service-unavailable-reply (taskmaster socket)
  "A helper function to send out a quick error reply, before any state
is set up via PROCESS-REQUEST."
  (let* ((acceptor (taskmaster-acceptor taskmaster))
         (*acceptor* acceptor)
         (*hunchentoot-stream*
          (initialize-connection-stream acceptor (make-socket-stream socket acceptor)))
         (*reply* (make-instance (acceptor-reply-class acceptor)))
         (*request*
          (multiple-value-bind (remote-addr remote-port)
              (get-peer-address-and-port socket)
            (make-instance (acceptor-request-class acceptor)
              :acceptor acceptor
              :remote-addr remote-addr
              :remote-port remote-port
              :headers-in nil
              :content-stream nil
              :method nil
              :uri nil
              :server-protocol nil))))
    (with-character-stream-semantics
      (send-response acceptor
                     (flex:make-flexi-stream *hunchentoot-stream* :external-format :iso-8859-1)
                     +http-service-unavailable+
                     :content (acceptor-status-message acceptor +http-service-unavailable+)))))

#-:lispworks
(defun client-as-string (socket)
  "A helper function which returns the client's address and port as a
   string and tries to act robustly in the presence of network problems."
  (let ((address (usocket:get-peer-address socket))
        (port (usocket:get-peer-port socket)))
    (when (and address port)
      (format nil "~A:~A"
              (usocket:vector-quad-to-dotted-quad address)
              port))))

#-:lispworks
(defmethod create-request-handler-thread ((taskmaster one-thread-per-connection-taskmaster) socket)
  "Create a thread for handling a single request"
  ;; we are handling all conditions here as we want to make sure that
  ;; the acceptor process never crashes while trying to create a
  ;; worker thread; one such problem exists in
  ;; GET-PEER-ADDRESS-AND-PORT which can signal socket conditions on
  ;; some platforms in certain situations.
  (handler-case*
   (bt:make-thread
    (lambda ()
      (unwind-protect
           (process-connection (taskmaster-acceptor taskmaster) socket)
        (decrement-taskmaster-request-count taskmaster)))
    :name (format nil (taskmaster-worker-thread-name-format taskmaster) (client-as-string socket)))
   (error (cond)
          ;; need to bind *ACCEPTOR* so that LOG-MESSAGE* can do its work.
          (let ((*acceptor* (taskmaster-acceptor taskmaster)))
            (log-message* *lisp-errors-log-level*
                         "Error while creating worker thread for new incoming connection will try to close this connection: ~A" cond)
	    (handler-case (usocket:socket-close socket) (error(error)(log-message* *lisp-errors-log-level* "while closing socket caught ~a" error)))))))

;; LispWorks implementation

#+:lispworks
(defmethod shutdown ((taskmaster taskmaster))
  (when-let (process (acceptor-process (taskmaster-acceptor taskmaster)))
    ;; kill the main acceptor process, see LW documentation for
    ;; COMM:START-UP-SERVER
    (mp:process-kill process))
  taskmaster)

#+:lispworks
(defmethod execute-acceptor ((taskmaster one-thread-per-connection-taskmaster))
  (accept-connections (taskmaster-acceptor taskmaster)))

#+:lispworks
(defmethod handle-incoming-connection ((taskmaster one-thread-per-connection-taskmaster) socket)
  (incf *worker-counter*)
  ;; check if we need to perform a global GC
  (when (and *cleanup-interval*
             (zerop (mod *worker-counter* *cleanup-interval*)))
    (when *cleanup-function*
      (funcall *cleanup-function*)))
  (cond ((null (taskmaster-max-thread-count taskmaster))
         ;; No limit on number of requests, just start a taskmaster
         (create-request-handler-thread taskmaster socket))
        ((if (taskmaster-max-accept-count taskmaster)
           (>= (taskmaster-request-count taskmaster) (taskmaster-max-accept-count taskmaster))
           (>= (taskmaster-request-count taskmaster) (taskmaster-max-thread-count taskmaster)))
         ;; Send HTTP 503 to indicate that we can't handle the request right now
         (too-many-taskmaster-requests taskmaster socket)
         (send-service-unavailable-reply taskmaster socket))
        ((and (taskmaster-max-accept-count taskmaster)
              (>= (taskmaster-request-count taskmaster) (taskmaster-max-thread-count taskmaster)))
         ;; Lispworks doesn't have condition variables, so punt
         (too-many-taskmaster-requests taskmaster socket)
         (send-service-unavailable-reply taskmaster socket))
        (t
         ;; We're within both limits, just start a taskmaster
         (increment-taskmaster-request-count taskmaster)
         (create-request-handler-thread taskmaster socket))))

#+:lispworks
(defmethod create-request-handler-thread ((taskmaster one-thread-per-connection-taskmaster) socket)
  (mp:process-run-function (format nil "hunchentoot-worker~{-~A:~A~})"
                                   (multiple-value-list (get-peer-address-and-port socket)))
                           nil
                           (lambda ()
                             (unwind-protect
                                 (process-connection (taskmaster-acceptor taskmaster) socket)
                               (decrement-taskmaster-request-count taskmaster)))))

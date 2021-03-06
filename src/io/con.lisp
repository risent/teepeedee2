(in-package #:tpd2.io)

(defstruct (con (:constructor %make-con))
  socket
  peer-info
  (recv (make-recvbuf) :type recvbuf)
  timeout

  ready-callback
  err)

(defun make-con (&rest args)
  (let ((con (apply '%make-con args)))
    (let ((sock (con-socket con)))
      (assert sock)
      (finalize con 
		(lambda()
		  (ignore-errors (socket-close sock)))))
    (con-init con)
    con))

(my-defun con init ()
  (unless (my err)
    (my clear-failure-callbacks))
  (unless (my timeout)
    (setf (my timeout) (make-timeout :func (lambda() (my fail 'timeout))))))

(my-defun con fail (&optional (e (make-condition 'socket-explicitly-hungup)))
  (let ((c (my err)))
    (my clear-failure-callbacks)
    (funcall c e))) 

(defgeneric normal-connection-error (e))
(defmethod normal-connection-error (e)
  (declare (ignore e)))
(defmethod normal-connection-error ((e socket-error))
  t)
(defmethod normal-connection-error ((e match-failed))
  t)
(defmethod normal-connection-error ((e syscall-failed))
  t)

(my-defun con run ()
  (restart-case
      (handler-bind ((error 
		      (lambda(e)
			(when (normal-connection-error e)
			  (invoke-restart 'hangup e)))))
	(funcall (my ready-callback)))
    (hangup (&optional (err (make-condition 'socket-explicitly-hungup)))
      (my fail err))))

(my-defun con 'reset-timeout (&optional delay)
  (timeout-set (my timeout) delay)
  (values))

(define-constant +newline+ (force-byte-vector #(13 10))
  :test 'equalp)

(my-defun con set-callback (func)
  (setf (my ready-callback) func))

(my-defun con add-failure-callback (func)
  (let ((old (my err)))
    (setf (my err) 
	  (if old
	      (lambda(e)
		(funcall old e)
		(funcall func e))
	      func))
    (values)))

(my-defun con clear-failure-callbacks ()
  (setf (my err) 
	(lambda(err)
	  (declare (ignore err))
	  (my 'hangup))))

(my-defun con 'recv (done amount)
  (declare (type fixnum amount))
  (cond
    ((>= (recvbuf-available-to-eat (my recv)) amount)
     (funcall done (recvbuf-eat (my recv) amount)))
    (t
     (recvbuf-prepare-read (my recv) amount)
     (recvbuf-recv (my recv) me #'my-call))))

(my-defun con 'recv-some-or-nil (done)
  (let ((available (recvbuf-available-to-eat (my recv))))
    (cond 
      ((zerop available)
       (let ((s (recvbuf-read-some (my recv) me #'my-call)))
	(case s
	  ((nil))
	  (0
	   (funcall done nil)
	   (return-from my-call))
	  (t
	   (debug-assert (not (zerop (recvbuf-available-to-eat (my recv)))))
	   (my-call)))))
      (t
       (funcall done (recvbuf-eat (my recv) available)))))
  (values))

(my-defun con peek ()
  (recvbuf-peek (my recv)))

(my-defun con 'recvline (done)
  (declare (type function done))
  (acond
   ((recvbuf-eat-to-delimiter (my recv) +newline+)
    (funcall done it))
   (t 
    (recvbuf-prepare-read (my recv))
    (recvbuf-recv (my recv) me #'my-call))))

(my-defun con 'recv-until-close (done)
  (let ((total))
    (labels ((r (buf)
	       (cond ((not buf)
		      (funcall done (apply-byte-vector-cat (nreverse total))))
		     (t
		      (push (copy-byte-vector buf) total)
		      (recv-some-or-nil me #'r)))))
      (recv-some-or-nil me #'r))))

(my-defun con 'send (done sendbuf)
  (cond
    ((sendbuf-done sendbuf)
     (funcall done))
    (t
     (if (socket-supports-writev (my socket))
	 (sendbuf-send-writev sendbuf me #'my-call)
	 (sendbuf-send-write sendbuf me #'my-call)))))

(my-defun con 'accept (done)
  (acond 
      ((socket-accept (my socket))
       (funcall done it))
      (t
       (my when-ready-to-read #'my-call))))

(my-defun con 'hangup ()
  (timeout-cancel (my timeout))
  (when (my socket)
    (cancel-finalization me)
    (socket-close (my socket))
    (setf (my socket) nil)))


(defun make-con-connect (&key address port 	       
		(socket-family +AF_INET+) 
		(socket-type +SOCK_STREAM+))
  (make-con :socket (make-connect-socket
		     :port port
		     :address address 
		     :socket-family socket-family
		     :socket-type socket-type)))

(defun make-con-listen (&key (port 0) 
	       (address "0.0.0.0") 
	       (socket-family +AF_INET+) 
	       (socket-type +SOCK_STREAM+))
  (make-con :socket (make-listen-socket 
		     :port port 
		     :address address 
		     :socket-family socket-family
		     :socket-type socket-type)))

(defun make-con-bind (&key (port 0)
	       (address "0.0.0.0") 
	       (socket-family +AF_INET+) 
	       (socket-type +SOCK_DGRAM+))
  (make-con :socket (make-listen-socket 
		     :port port 
		     :address address 
		     :socket-family socket-family
		     :socket-type socket-type)))

(my-defun con when-ready (events &optional callback)
  (my-declare-fast-inline)
  (when callback
    (my set-callback callback))
  (socket-register (my socket) events me)
  (values))

(my-defun con when-ready-to-write (&optional callback)
  (my-declare-fast-inline)
  (my when-ready +POLLOUT+ callback))

(my-defun con when-ready-to-read (&optional callback)
  (my-declare-fast-inline)
  (my when-ready (logior +POLLIN+ +POLLRDHUP+) callback))

(my-defun con dead? ()
  (not (my socket)))

(my-defun con connected? ()
  (not (not (socket-peer (my socket)))))

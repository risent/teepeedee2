(in-package #:tpd2.webapp)

(defvar *channels* (trivial-garbage:make-weak-hash-table :weakness :value :test 'equalp))

(defmyclass channel
  (id (random-web-sparse-key 10))
  (state 0)
  (subscribers nil))

(my-defun channel 'initialize-instance :after (&key)
  (setf (gethash (my id) *channels*) me))

(my-defun channel notify ()
  (let ((subscribers (my subscribers)))
    (setf (my subscribers) nil)
    (incf (my state))
    (loop for s in subscribers do (funcall s))
    (values)))

(my-defun channel subscribe (f)
  (push f (my subscribers)))
(my-defun channel unsubscribe (f)
  (deletef f (my subscribers)))

(defun find-channel (id)
  (gethash id *channels*))

(defgeneric channel-update (channel subscriber-state))

(defun channel-respond-page (dispatcher con done path all-http-params)
  (declare (ignore dispatcher path))
  (apply-page-call con 'channel-respond con done (.channels.)))

(defun channel-string-to-states (channels)
  (let ((channel-states))
    (match-bind ( (* channel "|" (state (integer)) (or ";" (last)) 
		     '(awhen (find-channel channel) (push (cons it state) channel-states))))
	channels)
    channel-states))

(defun channel-respond-body (channel-states)
  (let (at-least-one)
    (let ((sendbuf
	   (with-ml-output
	     (loop for (channel . state) in channel-states do
		   (unless (eql state (channel-state channel))
		     (setf at-least-one t)
		     (output-raw-ml (js-to-string (channel 
						   (unquote (force-string (channel-id channel))) 
						   (unquote (channel-state channel)))))
		     (output-raw-ml (channel-update channel state))))
	     (output-raw-ml (js-to-string (trigger-fetch-channels))))))
      (when at-least-one
	sendbuf))))

(defun channel-respond (con done &key .channels.)
  (let ((channel-states (channel-string-to-states .channels.)))
    (with-preserve-specials (*webapp-frame*) 
      (flet ((finished () 
	       (when (con-dead? con)
		 (return-from finished t))
	       (with-specials-restored
		   (with-frame-site 
		     (awhen (channel-respond-body channel-states)
		       (respond-http con done :headers +http-header-html-content-type+ :body it)
		       t)))))
      (unless (finished)
	(let (func)
	  (flet ((unsubscribe ()
		   (loop for (channel ) in channel-states do (channel-unsubscribe channel func))))
	    (setf func
		  (lambda() (when (finished) (unsubscribe))))
	    (loop for (channel ) in channel-states do (channel-subscribe channel func)))))))))

(defun register-channel-page ()
  (dispatcher-register-path (site-dispatcher (current-site)) +channel-page-name+ #'channel-respond-page))

(my-defun channel 'object-to-ml ()
  (js-html-script (channel (unquote (force-string (my id))) (unquote (my state)))))


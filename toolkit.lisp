#|
 This file is a part of cl-steamworks
 (c) 2019 Shirakumo http://tymoon.eu (shinmera@tymoon.eu)
 Author: Nicolas Hafner <shinmera@tymoon.eu>
|#

(in-package #:org.shirakumo.fraf.steamworks)

(or (maybe-load-low-level)
    (alexandria:simple-style-warning "No low-level file present. Please install the SteamWorks SDK:
Load cl-steamworks-generator and then run (cl-steamworks-generator:setup)"))

(defmacro with-cleanup-on-failure (cleanup &body body)
  (let ((err (gensym "ERROR")))
    `(let ((,err T))
       (unwind-protect
            (multiple-value-prog1 (progn ,@body)
              (setf ,err NIL))
         (when ,err
           ,cleanup)))))

(defmacro with-error-on-failure (form)
  (let ((result (gensym "RESULT")))
    `(let ((,result ,form))
       (unless (eql :ok ,result)
         (error "FIXME: failed ~a" ,result)))))

(defun calloc (type &optional (count 1))
  (let ((ptr (cffi:foreign-alloc type :count count)))
    (dotimes (i (* count (cffi:foreign-type-size type)) ptr)
      (setf (cffi:mem-aref ptr :uchar i) 0))))

(defun warn* (datum &rest args)
  (let ((condition (etypecase datum
                     (string (make-condition 'simple-warning :format-control datum :format-arguments args))
                     (symbol (apply #'make-condition 'datum args))
                     (condition datum))))
    (format *error-output* "~&WARNING: ~a~%" condition)
    (warn condition)))

;; This fucking sucks man
(defun foreign-type-p (type)
  (handler-bind ((warning #'muffle-warning))
    (not (null (ignore-errors (cffi:foreign-type-size type))))))

(defun env-var (x)
  #+(or abcl clasp clisp ecl xcl) (ext:getenv x)
  #+allegro (sys:getenv x)
  #+clozure (ccl:getenv x)
  #+cmucl (unix:unix-getenv x)
  #+scl (cdr (assoc x ext:*environment-list* :test #'string=))
  #+gcl (system:getenv x)
  #+lispworks (lispworks:environment-variable x)
  #+mkcl (#.(or (find-symbol* 'getenv :si nil) (find-symbol* 'getenv :mk-ext nil)) x)
  #+sbcl (sb-ext:posix-getenv x))

(defun chdir (x)
  #+(or abcl xcl) (setf *default-pathname-defaults* (truename x))
  #+allegro (excl:chdir x)
  #+clisp (ext:cd x)
  #+clozure (setf (ccl:current-directory) x)
  #+(or cmucl scl) (unix:unix-chdir (ext:unix-namestring x))
  #+(or clasp ecl) (ext:chdir x)
  #+gcl (system:chdir x)
  #+lispworks (hcl:change-directory x)
  #+mkcl (mk-ext:chdir x)
  #+sbcl (sb-posix:chdir (sb-ext:native-namestring x)))

(defun quit (&optional (code 0))
  (finish-output *standard-output*)
  (finish-output *error-output*)
  #+(or abcl xcl) (ext:quit :status code)
  #+allegro (excl:exit code :quiet t)
  #+(or clasp ecl) (si:quit code)
  #+clisp (ext:quit code)
  #+clozure (ccl:quit code)
  #+(or cmucl scl) (unix:unix-exit code)
  #+gcl (system:quit code)
  #+lispworks (lispworks:quit :status code :confirm nil :return nil :ignore-errors-p t)
  #+mkcl (mk-ext:quit :exit-code code)
  #+sbcl (sb-ext:exit :code code))

(defun temp-directory ()
  #+windows (parse-namestring (env-var "TEMP"))
  #-windows #p"/tmp/")

(defun setup-app-id (app-id)
  (let ((directory (merge-pathnames "cl-steamworks/" (temp-directory))))
    (chdir (ensure-directories-exist directory))
    (with-open-file (stream (merge-pathnames #p"steam_appid.txt" directory)
                            :direction :output
                            :if-exists :supersede
                            :element-type 'character)
      (format stream "~a~%" app-id))))

(defun enlist (a &rest items)
  (if (listp a) a (list* a items)))

(defun delist (a)
  (if (listp a) (first a) a))

(defmacro t-or (&rest clauses)
  (when clauses
    (let ((result (gensym "RESULT")))
      `(let ((,result ,(first clauses)))
         (if (eql T ,result)
             (t-or ,@(rest clauses))
             ,result)))))

(defun ipv4->int (ipstring)
  (let* ((d1 (position #\. ipstring))
         (d2 (position #\. ipstring :start (1+ d1)))
         (d3 (position #\. ipstring :start (1+ d2)))
         (x 0))
    (setf (ldb (byte 8 24) x) (parse-integer ipstring :start 0 :end d1))
    (setf (ldb (byte 8 16) x) (parse-integer ipstring :start (1+ d1) :end d2))
    (setf (ldb (byte 8  8) x) (parse-integer ipstring :start (1+ d2) :end d3))
    (setf (ldb (byte 8  0) x) (parse-integer ipstring :start (1+ d3)))
    x))

(defun remove-all (sequence &rest items)
  (remove-if (lambda (i) (find i items)) sequence))

(defun flags (enum &rest flags)
  (flet ((flag-value (flag)
           (if (integerp flag)
               flag
               (cffi:foreign-enum-value enum flag))))
    (reduce #'logior flags :key #'flag-value)))

(defun decode-flags (enum flags)
  (loop for flag in (cffi:foreign-enum-keyword-list enum)
        when (< 0 (logand flags (cffi:foreign-enum-value enum flag)))
        collect flag))

(defun struct-slot-ptr (struct slot)
  (cffi:foreign-slot-pointer (steam::_handle struct) (list :struct (type-of struct)) slot))

(defun struct-string (struct slot count)
  (cffi:foreign-string-to-lisp (struct-slot-ptr struct slot) :count count :encoding :utf-8))

(defun unix->universal (unix)
  (+ unix (encode-universal-time 0 0 0 1 1 1970 0)))

(defun universal->unix (universal)
  (- universal (encode-universal-time 0 0 0 1 1 1970 0)))

(defun account-id (id)
  (logand id #xFFFFFFFF))

(defun split-string (string split &optional (start 0))
  (let ((parts ())
        (buffer (make-string-output-stream)))
    (flet ((commit ()
             (let ((string (get-output-stream-string buffer)))
               (when (string/= "" string)
                 (push string parts)))))
      (loop for i from start below (length string)
            for char = (aref string i)
            do (if (char= char split)
                   (commit)
                   (write-char char buffer))
            finally (commit))
      (nreverse parts))))

(defun printable-char-p (char)
  ;; According to https://en.cppreference.com/w/c/string/byte/isprint
  ;; which is in the steam api for some reason.
  (find char "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~"))

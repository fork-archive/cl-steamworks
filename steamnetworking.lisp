#|
 This file is a part of cl-steamworks
 (c) 2019 Shirakumo http://tymoon.eu (shinmera@tymoon.eu)
 Author: Nicolas Hafner <shinmera@tymoon.eu>
|#

(in-package #:org.shirakumo.fraf.steamworks)

(defclass steamnetworking (interface)
  ())

(defmethod initialize-instance :after ((interface steamnetworking) &key version steamworks)
  (setf (handle interface) (get-interface-handle* steamworks 'steam::client-get-isteam-networking
                                                  (t-or version steam::steamnetworking-interface-version))))

(define-interface-method steamnetworking (setf p2p-packet-relay-allowed-p) (value steam::networking-allow-p2ppacket-relay))

(defmethod next-packet-size ((interface steamnetworking) &optional (channel 0))
  (cffi:with-foreign-object (size :uint32)
    (when (steam::networking-is-p2ppacket-available (handle interface) size channel)
      (cffi:mem-ref size :uint32))))

(defmethod read-packet ((interface steamnetworking) (buffer vector) &optional (channel 0))
  (cffi:with-foreign-objects ((size :uint32)
                              (remote 'steam::steam-id))
    (cffi:with-pointer-to-vector-data (data buffer)
      (unless (steam::networking-read-p2ppacket (handle interface) data (length buffer) size remote channel)
        (error "FIXME: no data"))
      (values (interface-object (cffi:mem-ref remote 'steam::steam-id) interface)
              (cffi:mem-ref size :uint32)))))

(defmethod read-packet ((interface steamnetworking) (buffer (eql T)) &optional (channel 0))
  (let ((buffer (cffi:make-shareable-byte-vector (next-packet-size interface channel))))
    (values buffer
            (read-packet interface buffer channel))))

(defclass p2p-session (c-managed-object interface-object)
  ()
  (:default-initargs :interface 'steamnetworking))

(defmethod initialize-instance :after ((session p2p-session) &key)
  (unless (steam::networking-accept-p2psession-with-user (iface* session) (handle session))
    (error "FIXME: failed")))

(defmethod allocate-handle ((session p2p-session) &key user)
  (handle user))

(defmethod free-handle-function ((session p2p-session) handle)
  (let ((interface (iface* session)))
    (lambda () (steam::networking-close-p2psession-with-user interface handle))))

(define-interface-submethod p2p-session close-channel (steam::networking-close-p2pchannel-with-user (channel integer)))

(defmethod steam-id ((session p2p-session))
  (handle session))

(defmethod user ((session p2p-session))
  (make-instance 'friend :handle (handle session)))

(defmethod session-state ((session p2p-session))
  (cffi:with-foreign-object (state '(:struct steam::p2psession-state))
    (unless (steam::networking-get-p2psession-state (iface* session) (handle session) state)
      (error "FIXME: failed"))
    (cffi:mem-ref state '(:struct steam::p2psession-state))))

(defmethod send-packet ((session p2p-session) (buffer vector) &key (transmission :reliable) (channel 0) start end)
  (cffi:with-pointer-to-vector-data (data buffer)
    (unless end (setf end (length buffer)))
    (when start
      (cffi:incf-pointer data start)
      (decf end start))
    (unless (steam::networking-send-p2ppacket (iface* session) (handle session) data end transmission channel)
      (error "FIXME: failed"))))

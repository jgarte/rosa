(in-package :cl-user)
(defpackage rosa.parse
  (:use :cl
        :trivial-gray-streams)
  (:import-from :anaphora
                :aif)
  (:export :peruse))
(in-package :rosa.parse)


(defmacro with-reader (instream &body body)
  `(let ((reader (if (subtypep (type-of ,instream)
                               'fundamental-character-input-stream)
                     #'(lambda () (stream-read-char ,instream))
                     #'(lambda () (read-char ,instream nil :eof))))
         (peeker (if (subtypep (type-of ,instream)
                               'fundamental-character-input-stream)
                     #'(lambda () (stream-peek-char ,instream))
                     #'(lambda () (peek-char nil ,instream nil :eof))))
         (unreader (if (subtypep (type-of ,instream)
                                 'fundamental-character-input-stream)
                       #'(lambda (c) (stream-unread-char ,instream c))
                       #'(lambda (c) (unread-char c ,instream)))))
     (declare (ignorable reader peeker unreader))
     ,@body))

(defmacro run-until-chars (chlist chvar instream outstream reader-type &body do-form)
  (let ((run-form `(with-reader ,instream
                     (loop :named run-until-chars
                        :for ,chvar := (funcall ,(ecase reader-type
                                                   (:read 'reader)
                                                   (:peek 'peeker)))
                        :while (and (not (eq ,chvar :eof))
                                    ,@(loop :for c :in chlist :collect `(char/= ,chvar ,c)))
                        :do (progn ,@do-form)))))
    (if outstream
        `(with-output-to-string (,outstream) ,run-form)
        run-form)))

(defmacro cond-escape-sequence (peek-fn eof escape-seq otherwise)
  (let ((peek (gensym)))
   `(let ((,peek (funcall ,peek-fn)))
      (cond ((eq ,peek :eof) ,eof)
            ((or (char= ,peek #\:) (char= ,peek #\;)) ,escape-seq)
            (t ,otherwise)))))

(defun read-label-identifier (stream)
  (labels ((identifier-first-char-p (ch)
             (or (and (<= (char-code #\a) (char-code ch))
                      (>= (char-code #\z) (char-code ch)))
                 (and (<= (char-code #\0) (char-code ch))
                      (>= (char-code #\9) (char-code ch)))))
           (identifier-char-p (ch)
             (or (identifier-first-char-p ch)
                 (char= ch #\-))))
    (with-output-to-string (out)
      (with-reader stream
        (loop
           :for c := (funcall peeker)
           :with first-p := t
           :while (and (not (eq c :eof))
                       (if first-p
                           (progn
                             (setf first-p nil)
                             (identifier-first-char-p c))
                           (identifier-char-p c)))
           :do (write-char (funcall reader) out))))))

(defun read-label (stream)
  "Read label and returns (block-p label body rest).
This function read chars **include newline**."
  (with-reader stream
    (cond-escape-sequence
     peeker
     (values nil nil nil (run-until-chars (#\newline) c stream out :read
                           (write-char c out)))
     (values nil nil nil (run-until-chars (#\newline) c stream out :read
                           (write-char c out)))
     (let ((label (read-label-identifier stream))
           (ch (funcall reader)))
       (cond ((eq ch :eof)              ; block but next is EOF ;(
              (return-from read-label (values t label nil nil)))
             ((char= ch #\space)        ; inline
              (values nil label
                      (run-until-chars (#\newline) c stream out :read
                        (write-char c out))
                      nil))
             ((char= ch #\newline)      ; truly, block
              (values t label nil nil))
             (t                   ; regard invalid identifier as plain
              (let* ((rest- (run-until-chars (#\newline) c stream out :read
                              (write-char c out)))
                     (rest (format nil "~a~c~a" label ch rest-)))
                (values nil nil nil rest))))))))

(defun read-block (stream)
  "Read block and returns (body label-p).
This function read chars **include newline**."

  (run-until-chars nil c stream out :read
    (labels ((read-to-eol ()
               (run-until-chars (#\newline) ch2 stream nil :peek
                 (write-char (funcall reader) out))))
      (cond ((char= c #\newline)
             (let ((peek (funcall peeker)))
               (when (and (characterp peek)
                          (char/= #\: peek))
                 (write-char #\newline out))))
            ((char= c #\:)
             (cond-escape-sequence peeker
                                   (return-from run-until-chars)
                                   (read-to-eol)
                                   (return-from read-block
                                     (values (get-output-stream-string out) t))))
            ((char= c #\;)
             (progn
               (run-until-chars (#\newline) ch1 stream nil :read)))
            (t (progn
                 (write-char c out)
                 (read-to-eol)))))))

(defun push-body (hash label body)
  (let ((key (intern label :keyword)))
    (if (gethash key hash)
        (vector-push-extend body (gethash key hash))
        (let ((val (make-array 1 :initial-element body :fill-pointer 1 :adjustable t)))
          (setf (gethash key hash) val)))))

(defun peruse (stream)
  "read key-value data."
  (with-reader stream
    (let ((data (make-hash-table)))
      (loop
         :for line := (funcall linereader)
         :until (eq c :eof)
         :finally (return-from peruse data)
         :do (labels ((read-colon ()
                        (multiple-value-bind (block-p label body rest)
                            (read-label stream)
                          (unless rest
                            (if block-p
                                (multiple-value-bind (body label-p)
                                    (read-block stream)
                                  (setf linehead-p t)
                                  (push-body data label body)
                                  (when label-p
                                    (read-colon)))
                                (progn
                                  (setf linehead-p t)
                                  (push-body data label body)))))))
               (cond ((char= c #\newline) (setf linehead-p t))
                     ((and linehead-p (char= c #\:))
                      (progn
                        (setf linehead-p nil)
                        (read-colon)))
                     (t (setf linehead-p nil))))))))


(defun escaped-line-p (line)
  (and (> (length line) 2)
       (or (char= (char line 1) #\:)
           (char= (char line 1) #\;))))

(defun peruse2 (stream)
  (let ((data (make-hash-table))
        (block-label)
        (block-text))
    (labels ((update-state-as-inline (label text)
               (setf block-label nil
                     block-text (make-string-output-stream))
               (push-body data label text))
             (update-state-as-block (label)
               (when block-label
                 (push-body data block-label (get-output-stream-string block-text)))
               (setf block-label label))
             (append-line-to-block (line)
               (when block-label
                 (format block-text "~a~%" line)))
             (colon-line (s)
               (if (escaped-line-p s)
                   (append-line-to-block (subseq s 1))
                   (aif (position #\space s)
                        (update-state-as-inline (subseq s 1 anaphora:it)
                                                (subseq s (1+ anaphora:it)))
                        (update-state-as-block (subseq s 1)))))
             (otherwise-line (s) (append-line-to-block s)))
      (loop :named parse
         :for line := (read-line stream nil :eof)
         :do (cond ((eq line :eof) (progn
                                     (update-state-as-block block-label)
                                     (return-from parse data)))
                   ((and (> (length line) 0)
                         (char= (char line 0) #\:))
                    (colon-line line))
                   ((and (> (length line) 0)
                         (char= (char line 0) #\;)) 'do-nothing)
                   (t (otherwise-line line)))))))

;;; GNU Guix --- Functional package management for GNU
;;; Copyright © 2017 Caleb Ristvedt <caleb.ristvedt@cune.org>
;;; Copyright © 2018 Ludovic Courtès <ludo@gnu.org>
;;;
;;; This file is part of GNU Guix.
;;;
;;; GNU Guix is free software; you can redistribute it and/or modify it
;;; under the terms of the GNU General Public License as published by
;;; the Free Software Foundation; either version 3 of the License, or (at
;;; your option) any later version.
;;;
;;; GNU Guix is distributed in the hope that it will be useful, but
;;; WITHOUT ANY WARRANTY; without even the implied warranty of
;;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;;; GNU General Public License for more details.
;;;
;;; You should have received a copy of the GNU General Public License
;;; along with GNU Guix.  If not, see <http://www.gnu.org/licenses/>.

(define-module (guix store database)
  #:use-module (sqlite3)
  #:use-module (guix config)
  #:use-module (guix serialization)
  #:use-module (guix base16)
  #:use-module (guix hash)
  #:use-module (rnrs io ports)
  #:use-module (srfi srfi-11)
  #:use-module (srfi srfi-19)
  #:use-module (ice-9 match)
  #:export (sqlite-register
            register-path))

;;; Code for working with the store database directly.


(define-syntax-rule (with-database file db exp ...)
  "Open DB from FILE and close it when the dynamic extent of EXP... is left."
  (let ((db (sqlite-open file)))
    (dynamic-wind noop
                  (lambda ()
                    exp ...)
                  (lambda ()
                    (sqlite-close db)))))

(define (last-insert-row-id db)
  ;; XXX: (sqlite3) currently lacks bindings for 'sqlite3_last_insert_rowid'.
  ;; Work around that.
  (let* ((stmt   (sqlite-prepare db "SELECT last_insert_rowid();"
                               #:cache? #t))
         (result (sqlite-fold cons '() stmt)))
    (sqlite-finalize stmt)
    (match result
      ((#(id)) id)
      (_ #f))))

(define path-id-sql
  "SELECT id FROM ValidPaths WHERE path = :path")

(define* (path-id db path)
  "If PATH exists in the 'ValidPaths' table, return its numerical
identifier.  Otherwise, return #f."
  (let ((stmt (sqlite-prepare db path-id-sql #:cache? #t)))
    (sqlite-bind-arguments stmt #:path path)
    (let ((result (sqlite-fold cons '() stmt)))
      (sqlite-finalize stmt)
      (match result
        ((#(id) . _) id)
        (_ #f)))))

(define update-sql
  "UPDATE ValidPaths SET hash = :hash, registrationTime = :time, deriver =
:deriver, narSize = :size WHERE id = :id")

(define insert-sql
  "INSERT INTO ValidPaths (path, hash, registrationTime, deriver, narSize)
VALUES (:path, :hash, :time, :deriver, :size)")

(define* (update-or-insert db #:key path deriver hash nar-size time)
  "The classic update-if-exists and insert-if-doesn't feature that sqlite
doesn't exactly have... they've got something close, but it involves deleting
and re-inserting instead of updating, which causes problems with foreign keys,
of course. Returns the row id of the row that was modified or inserted."
  (let ((id (path-id db path)))
    (if id
        (let ((stmt (sqlite-prepare db update-sql #:cache? #t)))
          (sqlite-bind-arguments stmt #:id id
                                 #:path path #:deriver deriver
                                 #:hash hash #:size nar-size #:time time)
          (sqlite-fold cons '() stmt)
          (sqlite-finalize stmt)
          (last-insert-row-id db))
        (let ((stmt (sqlite-prepare db insert-sql #:cache? #t)))
          (sqlite-bind-arguments stmt
                                 #:path path #:deriver deriver
                                 #:hash hash #:size nar-size #:time time)
          (sqlite-fold cons '() stmt)             ;execute it
          (sqlite-finalize stmt)
          (last-insert-row-id db)))))

(define add-reference-sql
  "INSERT OR IGNORE INTO Refs (referrer, reference) SELECT :referrer, id
FROM ValidPaths WHERE path = :reference")

(define (add-references db referrer references)
  "REFERRER is the id of the referring store item, REFERENCES is a list
containing store items being referred to.  Note that all of the store items in
REFERENCES must already be registered."
  (let ((stmt (sqlite-prepare db add-reference-sql #:cache? #t)))
    (for-each (lambda (reference)
                (sqlite-reset stmt)
                (sqlite-bind-arguments stmt #:referrer referrer
                                       #:reference reference)
                (sqlite-fold cons '() stmt)       ;execute it
                (sqlite-finalize stmt)
                (last-insert-row-id db))
              references)))

;; XXX figure out caching of statement and database objects... later
(define* (sqlite-register #:key db-file path (references '())
                          deriver hash nar-size)
  "Registers this stuff in a database specified by DB-FILE. PATH is the string
path of some store item, REFERENCES is a list of string paths which the store
item PATH refers to (they need to be already registered!), DERIVER is a string
path of the derivation that created the store item PATH, HASH is the
base16-encoded sha256 hash of the store item denoted by PATH (prefixed with
\"sha256:\") after being converted to nar form, and nar-size is the size in
bytes of the store item denoted by PATH after being converted to nar form."
  (with-database db-file db
    (let ((id (update-or-insert db #:path path
                                #:deriver deriver
                                #:hash hash
                                #:nar-size nar-size
                                #:time (time-second (current-time time-utc)))))
      (add-references db id references))))


;;;
;;; High-level interface.
;;;

;; XXX: Would it be better to just make WRITE-FILE give size as well? I question
;; the general utility of this approach.
(define (counting-wrapper-port output-port)
  "Some custom ports don't implement GET-POSITION at all. But if we want to
figure out how many bytes are being written, we will want to use that. So this
makes a wrapper around a port which implements GET-POSITION."
  (let ((byte-count 0))
    (make-custom-binary-output-port "counting-wrapper"
                                    (lambda (bytes offset count)
                                      (set! byte-count
                                        (+ byte-count count))
                                      (put-bytevector output-port bytes
                                                      offset count)
                                      count)
                                    (lambda ()
                                      byte-count)
                                    #f
                                    (lambda ()
                                      (close-port output-port)))))


(define (nar-sha256 file)
  "Gives the sha256 hash of a file and the size of the file in nar form."
  (let-values (((port get-hash) (open-sha256-port)))
    (let ((wrapper (counting-wrapper-port port)))
      (write-file file wrapper)
      (force-output wrapper)
      (force-output port)
      (let ((hash (get-hash))
            (size (port-position wrapper)))
        (close-port wrapper)
        (values hash size)))))

;; TODO: make this canonicalize store items that are registered. This involves
;; setting permissions and timestamps, I think. Also, run a "deduplication
;; pass", whatever that involves. Also, handle databases not existing yet
;; (what should the default behavior be?  Figuring out how the C++ stuff
;; currently does it sounds like a lot of grepping for global
;; variables...). Also, return #t on success like the documentation says we
;; should.

(define* (register-path path
                        #:key (references '()) deriver prefix
                        state-directory)
  ;; Priority for options: first what is given, then environment variables,
  ;; then defaults. %state-directory, %store-directory, and
  ;; %store-database-directory already handle the "environment variables /
  ;; defaults" question, so we only need to choose between what is given and
  ;; those.
  "Register PATH as a valid store file, with REFERENCES as its list of
references, and DERIVER as its deriver (.drv that led to it.)  If PREFIX is
given, it must be the name of the directory containing the new store to
initialize; if STATE-DIRECTORY is given, it must be a string containing the
absolute file name to the state directory of the store being initialized.
Return #t on success.

Use with care as it directly modifies the store!  This is primarily meant to
be used internally by the daemon's build hook."
  (let* ((db-dir (cond
                  (state-directory
                   (string-append state-directory "/db"))
                  (prefix
                   ;; If prefix is specified, the value of NIX_STATE_DIR
                   ;; (which affects %state-directory) isn't supposed to
                   ;; affect db-dir, only the compile-time-customized
                   ;; default should.
                   (string-append prefix %localstatedir "/guix/db"))
                  (else
                   %store-database-directory)))
         (store-dir (if prefix
                        ;; same situation as above
                        (string-append prefix %storedir)
                        %store-directory))
         (to-register (if prefix
                          (string-append %storedir "/" (basename path))
                          ;; note: we assume here that if path is, for
                          ;; example, /foo/bar/gnu/store/thing.txt and prefix
                          ;; isn't given, then an environment variable has
                          ;; been used to change the store directory to
                          ;; /foo/bar/gnu/store, since otherwise real-path
                          ;; would end up being /gnu/store/thing.txt, which is
                          ;; probably not the right file in this case.
                          path))
         (real-path (string-append store-dir "/" (basename path))))
    (let-values (((hash nar-size)
                  (nar-sha256 real-path)))
      (sqlite-register
       #:db-file (string-append db-dir "/db.sqlite")
       #:path to-register
       #:references references
       #:deriver deriver
       #:hash (string-append "sha256:"
                             (bytevector->base16-string hash))
       #:nar-size nar-size))))

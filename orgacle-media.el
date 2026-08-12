;;; orgacle-media.el --- Files, video and fringe indicators for Orgacle  -*- lexical-binding: t; -*-

;; This file is part of Orgacle.  See orgacle.el for the package header,
;; copyright and licence.

;;; Commentary:

;; Files, video and fringe indicators for Orgacle: showing an
;; auxiliary file alongside the current slide, playing video full
;; screen, and drawing the fringe indicators that announce extra
;; content on a slide.

;;; Code:

(require 'org)
(require 'orgacle-core)

;; `orgacle-show-file' calls `orgacle-get-mode-line', which lives in
;; orgacle-nav.el.  This file deliberately does not require
;; orgacle-nav, to avoid a sibling-module dependency (see P2's
;; modularization plan); the declaration below only quiets the
;; byte-compiler.
(declare-function orgacle-get-mode-line "orgacle-nav" ())

;; `pdf-tools' and `image-mode' are optional; every call site below is
;; guarded by a `major-mode' check.  These declarations only quiet the
;; byte-compiler.
(declare-function pdf-view-fit-height-to-window "pdf-view" ())
(declare-function pdf-view-fit-width-to-window "pdf-view" ())
(declare-function pdf-view-goto-page "pdf-view" (page &optional window))
(declare-function pdf-view-next-page "pdf-view" (&optional n))
;; `pdf-view-current-page' is a macro, so it cannot be declared here and
;; called from code compiled without pdf-tools loaded.  Its expansion is
;; this built-in accessor, which is an ordinary function.
(declare-function image-mode-window-get "image-mode" (prop &optional winprops))
(declare-function pdf-cache-number-of-pages "pdf-cache" ())
(declare-function image-transform-fit-to-height "image-mode" ())
(declare-function image-transform-fit-to-width "image-mode" ())

(defun orgacle-show-indicators-maybe ()
  "Draw the fringe indicators unless this slide displays its file by itself.
Nothing is drawn when `orgacle-indicators' is nil or when the heading
has an ORGACLE_SHOW_AUTO property."
  (let ((show-auto (org-entry-get nil "ORGACLE_SHOW_AUTO")))
    (when (and orgacle-indicators (not show-auto))
      (orgacle-show-indicators))))

(defun orgacle-show-indicators ()
  "Draw a fringe indicator for each medium this slide can show.
A filled square marks an ORGACLE_SHOW_FILE property and a hollow
square an ORGACLE_SHOW_VIDEO property."
  (interactive)
  (save-excursion
    (goto-char (point-min))
    (end-of-line)
    (let ((show-file nil))
      (when (org-entry-get nil "ORGACLE_SHOW_FILE")
        (setq show-file t)
        (add-to-list 'orgacle-fringe-overlays (make-overlay (point) (point)))
        (overlay-put (car orgacle-fringe-overlays)
                     'before-string
                     (propertize " " 'display '(right-fringe filled-square))))
      (when (org-entry-get nil "ORGACLE_SHOW_VIDEO")
        ;; advance past the drawer if a file indicator is already here
        (when show-file
          (re-search-forward "[ \t]*:END:")
          (forward-line))
        (add-to-list 'orgacle-fringe-overlays (make-overlay (point) (point)))
        (overlay-put (car orgacle-fringe-overlays)
                     'before-string
                     (propertize " " 'display '(right-fringe hollow-square)))))))

(defun orgacle-show-file (&optional filename size below)
  "Show FILENAME by splitting the current window.
If FILENAME is nil, the value of the ORGACLE_SHOW_FILE property is
used instead.  In either case, leading \"[[\" and trailing \"]]\" are
stripped, so that FILENAME can be an `org-mode' link; this is
convenient when FILENAME comes from a property, because it can then
be inspected easily from Org mode.

If BELOW is nil (the default), the new window is to the right of the
current one, otherwise it is below.  If BELOW is not given, the
ORGACLE_SHOW_BELOW property is looked up instead.

SIZE is the size of the new window, in lines when it is below and in
columns when it is to the right.  If SIZE is not given, the
ORGACLE_SHOW_SIZE property is used; if that is not set either, SIZE
defaults to half the window.

The displayed file is fit to width or height when it is a PDF or an
image.

After the file is displayed and fit, focus returns to the Orgacle
window, and changing slides deletes the auxiliary window showing the
file.  The file's buffer is refreshed every time it is shown."
  (interactive)
  ;; if FILENAME is not set, look at the property; do this, and error
  ;; out if neither is set, before touching the window layout
  (unless filename
    (setq filename (org-entry-get nil "ORGACLE_SHOW_FILE")))
  (unless filename
    (user-error "No file to show: set the ORGACLE_SHOW_FILE property"))
  (delete-other-windows)
  ;; remove [[ ]] in case they are there
  (setq filename (replace-regexp-in-string "^\\[\\[" "" filename))
  (setq filename (replace-regexp-in-string "\\]\\]$" "" filename))
  (if (not (file-exists-p filename))
      (user-error (concat filename " does not exist")))
  (when (not size)
    (setq size (org-entry-get nil "ORGACLE_SHOW_SIZE"))
    ;; convert to number, as properties are strings:
    (if (stringp size)
	(setq size (string-to-number size))))
  (if (not below)
      (setq below (org-entry-get nil "ORGACLE_SHOW_BELOW")))
  ;; negate size if not nil to conform to split-window-* conventions
  (if size (setq size (- size)))
  ;; clean fringe, otherwise indicators show up mid-screen
  (orgacle-clean-fringe-overlays)
  (if below
      (setq orgacle-aux-window (split-window-below size))
    (setq orgacle-aux-window (split-window-right size)))
  (select-window orgacle-aux-window)
  (find-file filename)
  (setq mode-line-format (orgacle-get-mode-line))
  (revert-buffer t t t)
  ;; PDFs
  (when (eq major-mode 'pdf-view-mode)
    (if below
	(pdf-view-fit-height-to-window)
      (pdf-view-fit-width-to-window))
    (pdf-view-goto-page 1)
    (orgacle-update-aux-fringe-overlay))
  ;; images
  (when (eq major-mode 'image-mode)
    (if below
	(image-transform-fit-to-height)
      (image-transform-fit-to-width)))
  ;; go back to presentation window:
  (select-window orgacle-presentation-window))

(defun orgacle-advance-file ()
  "Advance the file showed by orgacle-show-file to the next page."
  (interactive)
  (when (windowp orgacle-aux-window)
    (select-window orgacle-aux-window)
    (when (eq major-mode 'pdf-view-mode)
      (pdf-view-next-page)
      (orgacle-update-aux-fringe-overlay))
    (select-window orgacle-presentation-window)))

(defun orgacle-show-file-or-advance ()
  "Show a file with `orgacle-show-file', or advance within it.
If a file is already shown, advance within it using
`orgacle-advance-file' instead of showing it again."
  (interactive)
  (if (windowp orgacle-aux-window)
      (orgacle-advance-file)
    (orgacle-show-file)))

(defun orgacle-update-aux-fringe-overlay ()
  "Update the fringe indicator for more pages in the auxiliary PDF.
Delete the existing indicator, then draw a new right-arrow indicator
when the PDF shown in the auxiliary window has additional pages."
  (interactive)
  (if orgacle-aux-fringe-overlay
      (delete-overlay orgacle-aux-fringe-overlay))
  (when (eq major-mode 'pdf-view-mode)
    (when (< (image-mode-window-get 'page) (pdf-cache-number-of-pages))
      (setq orgacle-aux-fringe-overlay (make-overlay (point) (point)))
      (overlay-put
       orgacle-aux-fringe-overlay
       'before-string
       (propertize " " 'display '(right-fringe right-arrow))))))

(defun orgacle-show-file-auto ()
  "Show the current slide's file automatically, if requested.
This calls `orgacle-show-file' when the current heading has an
ORGACLE_SHOW_AUTO property."
  (if (org-entry-get nil "ORGACLE_SHOW_AUTO")
      (orgacle-show-file)))

(defun orgacle-show-video (&optional filename mute _paused)
  "Play a video full screen.

FILENAME is the video to play; without it the ORGACLE_SHOW_VIDEO
property of the current heading is used.  With MUTE non-nil the audio
is silenced; without it the ORGACLE_MUTE property is used.  The
player is chosen with `orgacle-video-player'."
  (interactive)
  (unless filename
    (setq filename (org-entry-get nil "ORGACLE_SHOW_VIDEO")))
  (unless filename
    (user-error "No video to show: set the ORGACLE_SHOW_VIDEO property"))
  (unless (file-exists-p filename)
    (user-error "Cannot open %s" filename))
  (unless mute
    (setq mute (org-entry-get nil "ORGACLE_MUTE")))
  (let ((command
         (cond
          ((string= orgacle-video-player "vlc")
           (concat "cvlc -f --no-osd " (if mute "--no-audio " "")
                   (shell-quote-argument filename)))
          ((string= orgacle-video-player "mplayer")
           (concat "mplayer -fs " (if mute "volume=-200dB " "")
                   (shell-quote-argument filename)))
          (t
           (user-error "Unsupported video player: %s"
                       orgacle-video-player)))))
    ;; leave full screen so the player can take it
    (set-frame-parameter nil 'fullscreen nil)
    (message "Executing %s" command)
    (shell-command command)
    (delete-other-windows)
    (set-frame-parameter nil 'fullscreen 'fullboth)
    (redraw-display)))

(provide 'orgacle-media)
;;; orgacle-media.el ends here

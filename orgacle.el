;;; orgacle.el --- Present Org-mode files as slide shows  -*- lexical-binding: t; -*-

;; Copyright (C) 2008 Tom Tromey <tromey@redhat.com>
;;               2010 Eric Schulte <schulte.eric@gmail.com>
;;               2020 Stefano Ghirlanda <drghirlanda@gmail.com>

;; Authors: Tom Tromey <tromey@redhat.com>
;;          Phil Hagelberg <technomancy@gmail.com>
;;          Eric Schulte <schulte.eric@gmail.com>
;;          Puneeth Chaganti <punchagan@gmail.com>
;;          Lee Hinman <lee@writequit.org>
;;          Stefano Ghirlanda <drghirlanda@gmail.com>
;; Maintainer: Stefano Ghirlanda <drghirlanda@gmail.com>
;; URL: https://github.com/drghirlanda/orgacle
;; Created: 12 Jun 2008
;; Version: 2.0.0
;; Keywords: outlines, hypermedia, multimedia
;; Package-Requires: ((emacs "29.1") (org "9.6"))

;; This file is not (yet) part of GNU Emacs.
;; However, it is distributed under the same license.

;; GNU Emacs is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 3, or (at your option)
;; any later version.

;; GNU Emacs is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs; see the file COPYING.  If not, write to the
;; Free Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
;; Boston, MA 02110-1301, USA.

;;; Commentary:

;; This is a presentation mode for Emacs.

;; To use, invoke `orgacle-run' in an `org-mode' buffer.  This will
;; make a full-screen frame special key bindings and features for
;; presentation.  Use n/p to navigate, or q to quit.  Read below for
;; more key bindings.  Each top-level headline becomes a frame in the
;; presentation (configure `ORGACLE_FRAME_LEVEL' to change this
;; default).  Org-mode markup is used to nicely display the buffer's
;; contents.

;; Orgacle began as a fork of epresent, by Tom Tromey, Phil Hagelberg,
;; Eric Schulte, Puneeth Chaganti and Lee Hinman, which has been
;; unmaintained since 2016.  Presentations written for the old package
;; use EPRESENT_ property names; `orgacle-migrate-buffer' converts them.

;;; Code:
(require 'org)
(require 'ox)
(require 'ox-latex)
(require 'cl-lib)
(require 'org-superstar nil t)
(require 'orgacle-core)
(require 'orgacle-nav)
(require 'orgacle-fontify)

;; `pdf-tools' and `image-mode' are optional; every call site below is
;; guarded by a `major-mode' check, except `flyspell-mode-off', which is
;; guarded by `fboundp' instead.  These declarations only quiet the
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
(declare-function flyspell-mode-off "flyspell" ())

;; functions

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

(defun orgacle-position-notes ()
  "Scroll the notes buffer to the notes for the current slide."
  (interactive)
  (when orgacle-notes-buffer
    (let* ((current-heading (org-entry-get nil "ITEM"))
           (find-me (concat "^\\*[ \t]+" (regexp-quote current-heading))))
      (with-selected-window (get-buffer-window orgacle-notes-buffer t)
        (widen)
        (goto-char (point-min))
        (re-search-forward find-me)
        (org-narrow-to-subtree)
        (recenter 0)))))

(defun orgacle-quit ()
  "Quit the current presentation."
  (interactive)
  (run-hooks 'orgacle-stop-presentation-hook)
  (org-clear-latex-preview)
  ;; restore the user's Org-mode variables
  (remove-hook 'org-src-mode-hook 'orgacle-setup-src-edit)
  ;; The saved preview overlays are not restored: Org 9.8 replaced the
  ;; variable that held them, and P3 rewrites this function around an
  ;; explicit session struct.  Previews regenerate on the next refresh.
  (setq org-src-fontify-natively orgacle-src-fontify-natively)
  (setq org-hide-emphasis-markers orgacle-hide-emphasis-markers)
  (set-display-table-slot standard-display-table
                          'selective-display orgacle-outline-ellipsis)
  (setq org-pretty-entities orgacle-pretty-entities)
  (remove-hook 'org-babel-after-execute-hook 'orgacle-refresh)
  (when (string= "Orgacle" (frame-parameter nil 'title))
    (delete-frame (selected-frame)))
  (when orgacle--org-file
    (let ((buf (get-file-buffer orgacle--org-file)))
      (when buf (kill-buffer buf)))
    (when (file-exists-p orgacle--org-file)
      (delete-file orgacle--org-file))
    (setq orgacle--org-file nil))
  (when orgacle--org-buffer
    (set-buffer orgacle--org-buffer))
  (org-mode)
  (if orgacle--org-restriction
      (apply #'narrow-to-region orgacle--org-restriction)
    (widen))
  (hack-local-variables)
  ;; delete all orgacle overlays
  (orgacle-clean-overlays)
  (orgacle-clean-fringe-overlays)
  ;; reset mouse pointer shape and colour
  (when (boundp 'x-pointer-shape)
    (setq x-pointer-shape orgacle-user-x-pointer-shape)
    (setq x-sensitive-text-pointer-shape
          orgacle-user-x-sensitive-text-pointer-shape)
    (setq void-text-area-pointer 'arrow)
    (set-mouse-color (cdr (assoc 'mouse-color (frame-parameters)))))
  ;; kill notes buffer and associated frame, if present
  (when (bufferp orgacle-notes-buffer)
    (delete-frame (window-frame (get-buffer-window orgacle-notes-buffer)))
    (kill-buffer orgacle-notes-buffer)))

(defun orgacle-setup-src-edit ()
  "Switch to a box cursor for editing a source block in place.
Added to `org-src-mode-hook' by `orgacle-mode'."
  (setq cursor-type 'box))

(defun orgacle-flash-cursor ()
  "Briefly show a hollow cursor, then restore the default cursor."
  (setq cursor-type 'hollow)
  (sit-for 0.5)
  (setq cursor-type nil))

(defun orgacle-next-src-block (&optional arg)
  "Move to the next source block and flash the cursor.
ARG is passed to `org-babel-next-src-block'."
  (interactive "P")
  (org-babel-next-src-block arg)
  (orgacle-flash-cursor))

(defun orgacle-previous-src-block (&optional arg)
  "Move to the previous source block and flash the cursor.
ARG is passed to `org-babel-previous-src-block'."
  (interactive "P")
  (org-babel-previous-src-block arg)
  (orgacle-flash-cursor))

(defun orgacle-toggle-hide-src-blocks (&optional arg)
  "Toggle the visibility of source block bodies.
With ARG non-nil, toggle only the source block at point; otherwise
toggle every source block in the buffer."
  (interactive "P")
  (cl-labels
      ((boundaries
        ()
        (let ((head (org-babel-where-is-src-block-head)))
          (if head
              (save-excursion
                (goto-char head)
                (looking-at org-babel-src-block-regexp)
                (list (match-beginning 5) (match-end 5)))
            (error "No source block to hide at %d" (point)))))
       (toggle
        ()
        (cl-destructuring-bind (beg end) (boundaries)
          (let ((ovs (cl-remove-if-not
                      (lambda (ov) (overlay-get ov 'orgacle-hidden-src-block))
                      (overlays-at beg))))
            (if ovs
                (unless (and orgacle-src-block-toggle-state
                             (eq orgacle-src-block-toggle-state :hide))
                  (progn
                    (mapc #'delete-overlay ovs)
                    (setq orgacle-overlays
                          (cl-set-difference orgacle-overlays ovs))))
              (unless (and orgacle-src-block-toggle-state
                           (eq orgacle-src-block-toggle-state :show))
                (progn
                  (push (make-overlay beg end) orgacle-overlays)
                  (overlay-put (car orgacle-overlays)
                               'orgacle-hidden-src-block t)
                  (overlay-put (car orgacle-overlays)
                               'invisible 'orgacle-hide))))))))
    (if arg (toggle)               ; only toggle the current src block
      (save-excursion              ; toggle all source blocks
        (goto-char (point-min))
        (while (re-search-forward org-babel-src-block-regexp nil t)
          (goto-char (1- (match-end 5)))
          (toggle))))
    (redraw-display)))

(defun orgacle-toggle-hide-src-block (&optional _arg)
  "Toggle the visibility of the source block at point.
ARG is accepted for the same calling convention as
`orgacle-toggle-hide-src-blocks' but is not otherwise used: this
command always toggles the block at point regardless of ARG."
  (interactive "P")
  (orgacle-toggle-hide-src-blocks t))

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

(defun orgacle--collect-notes ()
  "Return this buffer's speaker notes as Org text.
Each frame-level heading contributes a first-level heading, followed by
the body of its \"Speaker notes\" subtree when it has one."
  (let ((speaker-notes ""))
    (save-excursion
      (goto-char (point-min))
      (while (< (point) (point-max))
        (org-next-visible-heading 1)
        (let ((current-heading (org-entry-get nil "ITEM")))
          (when (= (org-current-level) 1)
            (setq speaker-notes
                  (concat speaker-notes "* " current-heading "\n")))
          (when (string= current-heading "Speaker notes")
            (org-mark-subtree)
            (setq speaker-notes
                  (concat speaker-notes
                          (buffer-substring (point) (mark))
                          "\n"))))))
    (deactivate-mark)
    speaker-notes))

(defun orgacle-make-notes-buffer ()
  "Collect speaker notes into a buffer and show it in a new frame."
  (interactive)
  (let ((notes (orgacle--collect-notes)))
    (if (bufferp orgacle-notes-buffer)
        (kill-buffer orgacle-notes-buffer))
    (setq orgacle-notes-buffer (generate-new-buffer "*Orgacle Notes*"))
    (with-current-buffer orgacle-notes-buffer
      (erase-buffer)
      (org-mode)
      (insert notes)
      (goto-char (point-min))
      (while (re-search-forward "\\*\\* ?.* Speaker [nN]otes[ \t]*\n" nil t)
        (replace-match ""))
      (goto-char (point-min))
      (org-narrow-to-subtree))
    (switch-to-buffer-other-frame orgacle-notes-buffer)))

;;; export functions

(require 'ox)
(require 'ox-org)

(defun orgacle-latex-property-drawer (blob contents _info)
  "Translate the property drawer BLOB with CONTENTS into LaTeX.
ORGACLE_VIDEO_ALT becomes a bracketed note naming the file.
ORGACLE_SHOW_FILE becomes an included Org file when it names one, and
an \\includegraphics otherwise, honouring ORGACLE_SHOW_WIDTH and
ORGACLE_SHOW_PAGES."
  (let ((input (org-export-expand blob contents t))
        (output nil))
    ;; videos are named, not embedded
    (when (string-match "ORGACLE_VIDEO_ALT:\s+\\(.+\\)" input)
      (setq output (concat output "\n[ Video: " (match-string 1 input) " ]\n\n")))
    (when (string-match "ORGACLE_SHOW_FILE:\s+\\(.+\\)" input)
      (let* ((filename (replace-regexp-in-string
                        "\\]?\\]?$" ""
                        (replace-regexp-in-string
                         "^\\[?\\[?" "" (match-string 1 input))))
             (extension (file-name-extension filename)))
        (if (string= extension "org")
            ;; Org files are converted to LaTeX and inlined.  Read the file
            ;; into a temporary buffer rather than visiting it: visiting
            ;; would hand us the user's own buffer if they have the file
            ;; open, and the conversion replaces the buffer's contents.
            (setq output
                  (concat output
                          (with-temp-buffer
                            (insert-file-contents filename)
                            (org-export-string-as (buffer-string) 'latex t))))
          ;; everything else is treated as an image
          (let ((width (if (string-match "ORGACLE_SHOW_WIDTH:\s+\\(.+\\)" input)
                           (match-string 1 input)
                         "0.5"))
                (pages (if (string-match "ORGACLE_SHOW_PAGES:\s+\\(.+\\)" input)
                           (split-string (match-string 1 input))
                         '("1"))))
            (setq output (concat output "\n"))
            (dolist (page pages)
              (setq output
                    (concat output
                            "\\includegraphics[width=" width
                            "\\textwidth,page=" page "]{" filename "}\n")))))))
    output))

(org-export-define-derived-backend 'orgacle 'latex
  :translate-alist
  '((property-drawer . orgacle-latex-property-drawer))
  :options-alist
  ;; Org drops property drawers unless this is on, which would silently
  ;; disable the translator above.  Default it to t for this backend only.
  '((:with-properties nil "prop" t))
  :menu-entry
  '(?E "Orgacle to LaTeX"
       ((?L "As LaTeX buffer" orgacle-export-as-latex)
	(?l "As LaTeX file" orgacle-export-to-latex)
	(?p "As PDF file" orgacle-export-to-pdf)
	(?o "As PDF file and open"
	    (lambda (a s v b)
	      (if a (orgacle-export-to-pdf t s v b)
		(org-open-file (orgacle-export-to-pdf nil s v b))))))))

;;;###autoload
(defun orgacle-export-as-latex
  (&optional async subtreep visible-only body-only ext-plist)
  "Export the current Orgacle buffer to a LaTeX buffer.
ASYNC, SUBTREEP, VISIBLE-ONLY, BODY-ONLY and EXT-PLIST are passed to
`org-export-to-buffer'; see there for their meaning."
  (interactive)
  (org-export-to-buffer 'orgacle "*Org LATEX Export*"
    async subtreep visible-only body-only ext-plist (lambda () (LaTeX-mode))))

;;;###autoload
(defun orgacle-export-to-latex
  (&optional async subtreep visible-only body-only ext-plist)
  "Export the current buffer to a LaTeX file.
ASYNC, SUBTREEP, VISIBLE-ONLY, BODY-ONLY and EXT-PLIST are passed to
`org-export-to-file'; see there for their meaning."
  (interactive)
  (let ((outfile (org-export-output-file-name ".tex" subtreep)))
    (org-export-to-file 'orgacle outfile
      async subtreep visible-only body-only ext-plist)))

;;;###autoload
(defun orgacle-export-to-pdf
  (&optional async subtreep visible-only body-only ext-plist)
  "Export the current Orgacle buffer to LaTeX, then process it to PDF.
ASYNC, SUBTREEP, VISIBLE-ONLY, BODY-ONLY and EXT-PLIST are passed to
`org-export-to-file'; see there for their meaning."
  (interactive)
  (let ((outfile (org-export-output-file-name ".tex" subtreep)))
    (org-export-to-file 'orgacle outfile
      async subtreep visible-only body-only ext-plist
      (lambda (file) (org-latex-compile file)))))

;;; end export functions

(defun orgacle--speaker-word-count ()
  "Return the number of words in this buffer's speaker-notes subtrees."
  (let ((speaker-words 0))
    (org-map-entries
     (lambda ()
       (when (string= (downcase (org-entry-get nil "ITEM")) "speaker notes")
         (save-excursion
           (org-mark-subtree)
           (setq speaker-words (+ speaker-words (count-words (point) (mark))))
           (deactivate-mark)))))
    speaker-words))

(defun orgacle--speaking-time (words)
  "Return the estimated time in minutes to speak WORDS aloud.
The result is rounded up to the next half minute.  The reading speed is
`orgacle-wpm'."
  (/ (ceiling (* (/ (float words) orgacle-wpm) 2)) 2.0))

(defun orgacle-estimate-time ()
  "Report how long it would take to read all speaker notes aloud.
The estimate and the word count are shown in the echo area.  The
reading speed is `orgacle-wpm'."
  (interactive)
  (let* ((words (orgacle--speaker-word-count))
         (minutes (orgacle--speaking-time words)))
    (message "Estimated speaking time in minutes: %s (%d words)"
             minutes words)))

(defvar orgacle-mode-map
  (let ((map (make-keymap)))
    (suppress-keymap map)
    ;; line movement
    (define-key map "j" 'scroll-up)
    (define-key map [down] 'scroll-up)
    (define-key map "k" 'scroll-down)
    (define-key map [up] 'scroll-down)
    ;; page movement
    (define-key map " " 'orgacle-next-page)
    (define-key map "n" 'orgacle-next-page)
    (define-key map "f" 'orgacle-next-page)
    (define-key map [right] 'orgacle-next-page)
    (define-key map [next] 'orgacle-next-page)
    (define-key map "p" 'orgacle-previous-page)
    (define-key map "b" 'orgacle-previous-page)
    (define-key map [left] 'orgacle-previous-page)
    (define-key map [prior] 'orgacle-previous-page)
    (define-key map [backspace] 'orgacle-previous-page)
    (define-key map "v" 'orgacle-jump-to-page)
    ;; within page functions
    (define-key map "c" 'orgacle-next-src-block)
    (define-key map "C" 'orgacle-previous-src-block)
    (define-key map "e" 'org-edit-src-code)
    (define-key map "E" 'orgacle-edit-text)   ; C-c C-c exits edit mode
    (define-key map "x" 'org-babel-execute-src-block)
    (define-key map "r" 'orgacle-refresh)
    (define-key map "R" 'redraw-display)
    (define-key map "g" 'orgacle-refresh)
    ;; navigate folded subheadings
    (define-key map "N" 'orgacle-next-subheading)
    (define-key map "P" 'orgacle-previous-subheading)
    ;; show/hide images and videos
    (define-key map "i" 'orgacle-show-file-or-advance)
    (define-key map "I" 'orgacle-show-video)
    ;; show/hide mouse pointer
    (define-key map "m" 'orgacle-toggle-mouse)
    ;; adjust font size
    (define-key map "+" 'orgacle-increase-font)
    (define-key map "-" 'orgacle-decrease-font)
    ;; global controls
    (define-key map "q" 'orgacle-quit)
    (define-key map "1" 'orgacle-top)
    (define-key map "s" 'orgacle-toggle-hide-src-blocks)
    (define-key map "S" 'orgacle-toggle-hide-src-block)
    (define-key map "t" 'orgacle-top)
    map)
  "Local keymap for Orgacle display mode.")

(define-derived-mode orgacle-mode org-mode "Orgacle"
  "Major mode for presenting an Org-mode buffer as a slide show.

Each frame-level heading becomes a slide.  Navigate with
\\<orgacle-mode-map>\\[orgacle-next-page] and \\[orgacle-previous-page], and leave with \\[orgacle-quit].

\\{orgacle-mode-map}"
  ;; make Org-mode be as pretty as possible
  (add-hook 'org-src-mode-hook 'orgacle-setup-src-edit)
  (setq orgacle-inline-image-overlays (orgacle--link-preview-overlays))
  (setq orgacle-src-fontify-natively org-src-fontify-natively)
  (setq org-src-fontify-natively t)
  (setq org-fontify-quote-and-verse-blocks t)
  (setq orgacle-hide-emphasis-markers org-hide-emphasis-markers)
  (setq org-hide-emphasis-markers t)
  (setq orgacle-outline-ellipsis
        (display-table-slot standard-display-table 'selective-display))
  (set-display-table-slot standard-display-table 'selective-display [32])
  (setq orgacle-pretty-entities org-pretty-entities)
  (setq org-pretty-entities t)
  (setq mode-line-format (orgacle-get-mode-line))
  (add-hook 'org-babel-after-execute-hook 'orgacle-refresh)
  (condition-case ex
      (let ((org-format-latex-options
             (plist-put (copy-tree org-format-latex-options)
                        :scale orgacle-format-latex-scale)))
        (org-latex-preview '(16)))
    (error
     (message "Unable to imagify latex [%s]" (error-message-string ex))))
  (set-face-attribute 'default orgacle--frame :height orgacle-text-scale)
  ;; fontify the buffer
  (add-to-invisibility-spec '(orgacle-hide))
  ;; remove flyspell overlays
  (when (fboundp 'flyspell-mode-off)
    (flyspell-mode-off))
  (orgacle-fontify)
  ;; hide headings with ORGACLE_HIDE tag or marked as "speaker notes"
  (org-map-entries (lambda ()
		     (when (or
			    (org-entry-get nil "ORGACLE_HIDE")
			    (string= (downcase (org-entry-get nil "ITEM")) "speaker notes")
			    (string= (downcase (org-entry-get nil "ITEM")) "title page"))
		       (org-mark-subtree)
		       ;; we make things insvisile only until mark-1
		       ;; to leave a newline visible, as a separator
		       ;; betwen this heading and the next
		       (push (make-overlay (point) (- (mark) 1)) orgacle-overlays)
		       (overlay-put (car orgacle-overlays)
				    'invisible
				    'orgacle-hide)
		       (deactivate-mark))))
  ;; reset the auxiliary window object
  (setq orgacle-aux-window nil))

(defvar orgacle-edit-map (let ((map (copy-keymap org-mode-map)))
                            (define-key map (kbd "C-c C-c") 'orgacle-refresh)
                            map)
  "Local keymap for editing an Orgacle presentation.")

(defun orgacle-edit-text ()
  "Edit the presentation text in place.
Press \\<orgacle-edit-map>\\[orgacle-refresh] to stop editing and refresh
the display."
  (interactive)
  (let ((prior-cursor-type (cdr (assoc 'cursor-type (frame-parameters)))))
    (set-frame-parameter nil 'cursor-type t)
    (use-local-map orgacle-edit-map)
    (set-transient-map
     orgacle-edit-map
     (lambda () (not (equal (kbd "C-c C-c") (this-command-keys))))
     (lambda ()
       (use-local-map orgacle-mode-map)
       (set-frame-parameter nil 'cursor-type prior-cursor-type)))))

;;;###autoload
(defun orgacle-run ()
  "Present an Org-mode buffer."
  (interactive)
  (unless (eq major-mode 'orgacle-mode)
    (unless (eq major-mode 'org-mode)
      (error "Orgacle can only be used from Org Mode"))
    (setq orgacle--org-buffer (current-buffer))
    ;; regenerate image previews
    (orgacle--link-preview-refresh)
    ;; To present narrowed region use temporary buffer
    (when (and (or (> (point-min) (save-restriction (widen) (point-min)))
                   (< (point-max) (save-restriction (widen) (point-max))))
               (save-excursion (goto-char (point-min)) (org-at-heading-p)))
      (let ((title (nth 4 (org-heading-components))))
        (setq orgacle--org-restriction (list (point-min) (point-max)))
        (require 'ox-org)
        (setq orgacle--org-file (org-org-export-to-org nil 'subtree))
        (find-file orgacle--org-file)
        (goto-char (point-min))
        (insert (format "#+Title: %s\n\n" title))))
    (setq orgacle-frame-level (orgacle-get-frame-level))
    (orgacle--get-frame)
    (orgacle-mode)
    (set-buffer-modified-p nil)
    (setq orgacle-presentation-window (selected-window))
    ;; set/unset tooltips
    (tooltip-mode (if orgacle-tooltip-mode 1 -1))
    ;; create speaker notes
    (when orgacle-speaker-notes (orgacle-make-notes-buffer))
    (run-hooks 'orgacle-start-presentation-hook)))

;;; Migration

;;;###autoload
(defun orgacle-migrate-buffer (&optional beg end)
  "Convert EPRESENT_ names to ORGACLE_ between BEG and END.
Without BEG and END, convert the accessible portion of the buffer, or
the region when one is active -- so a narrowed buffer only has its
visible part converted.  Return the number of substitutions, and
report it in the echo area when called interactively.

Presentations written before the ORGACLE_ rename use the older
names; this brings them up to date."
  (interactive (if (use-region-p)
                   (list (region-beginning) (region-end))
                 (list nil nil)))
  (let ((count 0)
        (case-fold-search nil))
    (save-excursion
      (save-restriction
        (when (and beg end) (narrow-to-region beg end))
        (goto-char (point-min))
        (while (re-search-forward "EPRESENT_" nil t)
          (replace-match "ORGACLE_" t t)
          (setq count (1+ count)))))
    (when (called-interactively-p 'interactive)
      (message "Converted %d name%s" count (if (= count 1) "" "s")))
    count))

;;;###autoload
(defun orgacle-migrate-file (file)
  "Convert EPRESENT_ names to ORGACLE_ in FILE, saving it.
The whole file is converted, regardless of any narrowing in an
already-open buffer visiting it.  When FILE is already open with
unsaved changes, ask first: saving it would write those changes too."
  (interactive "fMigrate file: ")
  (let ((visiting (find-buffer-visiting file)))
    (when (and visiting (buffer-modified-p visiting)
               (not (yes-or-no-p
                     (format "%s has unsaved changes that would also be saved.  Continue? "
                             (file-name-nondirectory file)))))
      (user-error "Migration cancelled")))
  (with-current-buffer (find-file-noselect file)
    (let ((count (save-restriction (widen) (orgacle-migrate-buffer))))
      (save-buffer)
      (message "Converted %d name%s in %s"
               count (if (= count 1) "" "s") (file-name-nondirectory file))
      count)))

(provide 'orgacle)
;;; orgacle.el ends here

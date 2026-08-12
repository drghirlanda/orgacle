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
(require 'cl-lib)
(require 'org-superstar nil t)
(require 'orgacle-core)
(require 'orgacle-nav)
(require 'orgacle-fontify)
(require 'orgacle-src)
(require 'orgacle-media)
(require 'orgacle-notes)
(require 'ox-orgacle)

;; `flyspell' is optional; the call site below is guarded by `fboundp'.
;; This declaration only quiets the byte-compiler.
(declare-function flyspell-mode-off "flyspell" ())

;; `x-pointer-shape' and `x-sensitive-text-pointer-shape' exist only on
;; X11 builds, where term/x-win.el defines them; see orgacle-core.el,
;; which declares them for its own use.  A value-less `defvar' only
;; informs the byte-compiler within the file it appears in -- it is not
;; a real, session-wide declaration the way a `defvar' with a value is
;; -- so `orgacle-quit', which sets both, needs its own copy here too.
;; The `boundp' guard at the call site is what decides anything at
;; runtime.
(defvar x-pointer-shape)
(defvar x-sensitive-text-pointer-shape)

;; functions

(defun orgacle-quit ()
  "Quit the current presentation.
Safe to call when no presentation is running, and safe to call twice:
every step is guarded on the thing it acts on actually existing, and
the user's Org-mode variables and display-table slot are restored in
an `unwind-protect' cleanup so a failure earlier in this function
still restores them."
  (interactive)
  (unwind-protect
      (progn
        (run-hooks 'orgacle-stop-presentation-hook)
        (org-clear-latex-preview)
        (remove-hook 'org-src-mode-hook 'orgacle-setup-src-edit)
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
          (set-buffer orgacle--org-buffer)
          (org-mode)
          (if orgacle--org-restriction
              (apply #'narrow-to-region orgacle--org-restriction)
            (widen))
          (hack-local-variables)
          (setq orgacle--org-buffer nil
                orgacle--org-restriction nil))
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
          (let ((win (get-buffer-window orgacle-notes-buffer)))
            (when win (delete-frame (window-frame win))))
          (kill-buffer orgacle-notes-buffer)
          (setq orgacle-notes-buffer nil)))
    ;; restore the user's Org-mode variables, even if something above failed
    (orgacle--restore-user-state)
    ;; `standard-display-table' only exists once something has created
    ;; it -- `orgacle-mode' does, when a presentation actually starts.
    ;; Guard on that instead of unconditionally calling
    ;; `set-display-table-slot': under byte-compilation, its first-ever
    ;; call in a process evaluates a nil DISPLAY-TABLE argument before
    ;; the autoloaded `disp-table.el' has a chance to auto-vivify the
    ;; table, and signals `wrong-type-argument' instead.
    (when (char-table-p standard-display-table)
      (set-display-table-slot standard-display-table
                              'selective-display orgacle-outline-ellipsis))))

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
  ;; `orgacle--save-user-state' captures both the tracked variables and
  ;; the outline-ellipsis display-table slot, and is a no-op when a save
  ;; is already pending -- see its docstring -- which is what makes
  ;; re-entering this mode without an intervening `orgacle-quit' safe.
  ;; It also vivifies `standard-display-table' when necessary, so by the
  ;; time control reaches the `set-display-table-slot' call below, the
  ;; table is guaranteed to be a real char-table; this mirrors the
  ;; `char-table-p' guard `orgacle-quit' uses on the way back.
  (orgacle--save-user-state)
  (setq org-src-fontify-natively t)
  (setq org-fontify-quote-and-verse-blocks t)
  (setq org-hide-emphasis-markers t)
  (set-display-table-slot standard-display-table 'selective-display [32])
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

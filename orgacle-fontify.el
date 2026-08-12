;;; orgacle-fontify.el --- Slide rendering for Orgacle  -*- lexical-binding: t; -*-

;; This file is part of Orgacle.  See orgacle.el for the package header,
;; copyright and licence.

;;; Commentary:

;; Slide rendering for Orgacle: fontifying the buffer for presentation,
;; the slide-in effect, and the font-scaling commands.

;;; Code:

(require 'orgacle-core)

(defun orgacle--slide-in-p ()
  "Return non-nil when the current slide should slide in.
`orgacle-slide-in' is the default; an ORGACLE_SLIDE_IN property of
\"no\", \"nil\" or \"off\" turns the animation off for one slide, and
any other value turns it on."
  (let ((property (org-entry-get nil "ORGACLE_SLIDE_IN")))
    (cond ((null property) orgacle-slide-in)
          ((member (downcase property) '("no" "nil" "off")) nil)
          (t t))))

(defun orgacle-slide-in-effect ()
  "Animate the current slide sliding in from below."
  (interactive)
  (when (orgacle--slide-in-p)
    (save-excursion
      (goto-char (point-min))
      (forward-line)
      ;; if there is a drawer, skip it
      (if (looking-at "[ \t]*:PROPERTIES:")
          (re-search-forward "^[ \t]*:END:[ \r\n]" nil t))
      (let ((ov (make-overlay (point) (point))))
        (dotimes (i orgacle-slide-in-lines)
          (if (eq i 1) (sit-for orgacle-slide-in-pause))
          (overlay-put ov 'after-string
                       (make-string (- orgacle-slide-in-lines i) ?\n))
          (sit-for (/ orgacle-slide-in-duration orgacle-slide-in-lines)))
        (delete-overlay ov)))))

(defconst orgacle-scalable-faces
  '(orgacle-title-face orgacle-heading-face orgacle-subheading-face
    orgacle-author-face orgacle-bullet-face)
  "Faces whose height `orgacle-increase-font' and its opposite change.")

(defconst orgacle-font-step 10
  "Amount `orgacle--scale-font' adds to or subtracts from an absolute height.
Applies to a face in `orgacle-scalable-faces' whose current :height is
an integer, i.e. an absolute size in 1/10 pt, such as
`orgacle-title-face'.")

(defconst orgacle-font-factor 1.1
  "Factor `orgacle--scale-font' multiplies or divides a relative height by.
Applies to a face in `orgacle-scalable-faces' whose current :height is
a float, i.e. a multiplier of the frame's default height, such as
`orgacle-author-face'.")

(defun orgacle--scale-font (grow)
  "Scale the height of every face in `orgacle-scalable-faces'.
With GROW non-nil the faces get larger, otherwise smaller.

`orgacle-scalable-faces' mixes faces whose :height is an absolute
integer with faces whose :height is a relative float multiplier.  An
absolute height is stepped by `orgacle-font-step'; a relative height
is scaled by `orgacle-font-factor'.  Either kind is clamped above
zero, so no sequence of calls can produce a non-positive height, which
`set-face-attribute' rejects."
  (dolist (face orgacle-scalable-faces)
    (let ((height (face-attribute face :height)))
      (set-face-attribute
       face nil :height
       (if (integerp height)
           (max 1 (+ height (if grow orgacle-font-step (- orgacle-font-step))))
         (max 0.1 (if grow (* height orgacle-font-factor)
                    (/ height orgacle-font-factor))))))))

(defun orgacle-increase-font ()
  "Make the presentation font one step larger."
  (interactive)
  (orgacle--scale-font t))

(defun orgacle-decrease-font ()
  "Make the presentation font one step smaller."
  (interactive)
  (orgacle--scale-font nil))

(defun orgacle-fontify ()
  "Overlay additional presentation faces to Org-mode."
  (save-excursion
    ;; hide all comments
    (goto-char (point-min))
    (while (re-search-forward
            "^[ \t]*#\\(\\+\\(author\\|title\\|date\\):\\)?.*\n"
            nil t)
      (cond
       ;; this avoids hiding title, author, or date
       ((and (match-string 2)
             (save-match-data
               (string-match (regexp-opt '("title" "author" "date"))
                             (match-string 2)))))
       ;; special handling of #+results
       ((and (match-string 2)
	     (save-match-data
	       (string-match org-babel-results-keyword (match-string 2))))
        ;; This pulls back the end of the hidden overlay by one to
        ;; avoid hiding image results of code blocks.  I'm not sure
        ;; why this is required, or why images start on the preceding
        ;; newline, but not knowing why doesn't make it less true.
        (push (make-overlay (match-beginning 0) (- (match-end 0) 1))
              orgacle-overlays)
        (overlay-put (car orgacle-overlays) 'invisible 'orgacle-hide))
       ((save-match-data
	  (string-match "^[ \t]*#\\+attr_org:.*?\n" (match-string 0)))
        (push (make-overlay (match-beginning 0) (- (match-end 0) 1))
              orgacle-overlays)
        (overlay-put (car orgacle-overlays) 'invisible 'orgacle-hide))
       ;; this hides all other comments
       (t (push (make-overlay (match-beginning 0) (match-end 0))
                orgacle-overlays)
          (overlay-put (car orgacle-overlays) 'invisible 'orgacle-hide))))
    ;; page title faces and heading/subheading faces
    (goto-char (point-min))
    (while (re-search-forward "^\\(*+\\)\\([ \t]+\\)\\(.*\\)$" nil t)
      ;; hide the first match, that is the stars
      (push (make-overlay (match-beginning 1) (or (match-end 2)
                                                 (match-end 1)))
           orgacle-overlays)
      (overlay-put (car orgacle-overlays) 'invisible 'orgacle-hide)
      ;; apply faces to heading and subheading
      (push (make-overlay (match-beginning 3) (match-end 3)) orgacle-overlays)
      (if (> (length (match-string 1)) 1)
          (overlay-put (car orgacle-overlays) 'face 'orgacle-subheading-face)
	  (overlay-put (car orgacle-overlays) 'face 'orgacle-heading-face)))
    ;; fancy bullet points, when the package is available
    (when (and orgacle-use-org-superstar (fboundp 'org-superstar-mode))
      (org-superstar-mode 1))
    ;; hide todos
    (when orgacle-hide-todos
      (goto-char (point-min))
      (while (re-search-forward org-todo-line-regexp nil t)
        (when (match-string 2)
          (push (make-overlay (match-beginning 2) (1+ (match-end 2)))
                orgacle-overlays)
          (overlay-put (car orgacle-overlays) 'invisible 'orgacle-hide))))
    ;; hide tags
    (when orgacle-hide-tags
      (goto-char (point-min))
      (while (re-search-forward
              "^\\*+.*?\\([ \t]+:[[:alnum:]_@#%:]+:\\)[ \r\n]"
              nil t)
        (push (make-overlay (match-beginning 1) (match-end 1)) orgacle-overlays)
        (overlay-put (car orgacle-overlays) 'invisible 'orgacle-hide)))
    ;; hide properties
    (when orgacle-hide-properties
      (goto-char (point-min))
      (while (re-search-forward org-drawer-regexp nil t)
        (let ((beg (match-beginning 0))
              (end (re-search-forward
                    "^[ \t]*:END:[ \r\n]"
                    (save-excursion (outline-next-heading) (point)) t)))
          (push (make-overlay beg end) orgacle-overlays)
          (overlay-put (car orgacle-overlays) 'invisible 'orgacle-hide))))
    (dolist (el '("title" "author" "date"))
      (goto-char (point-min))
      (when (re-search-forward (format "^\\(#\\+%s:[ \t]*\\)[ \t]*\\(.*\\)$" el) nil t)
        (push (make-overlay (match-beginning 1) (match-end 1)) orgacle-overlays)
        (overlay-put (car orgacle-overlays) 'invisible 'orgacle-hide)
        (push (make-overlay (match-beginning 2) (match-end 2)) orgacle-overlays)
        (overlay-put
         (car orgacle-overlays) 'face (intern (format "orgacle-%s-face" el)))))
    ;; inline images
    (orgacle--link-preview-clear)
    (orgacle--link-preview-refresh)))

(defun orgacle-refresh ()
  "Delete the current slide's overlays and re-fontify it."
  (interactive)
  (orgacle-clean-overlays (point-min) (point-max))
  (orgacle-fontify))

(provide 'orgacle-fontify)
;;; orgacle-fontify.el ends here

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

;; `orgacle--build-notes-buffer' is defined in orgacle-notes.el, a
;; sibling module loaded after this one -- see the Makefile's EL list
;; and orgacle.el's `require' order.  `orgacle-refresh' below needs it
;; to keep a live notes buffer in step with a rebuilt
;; `orgacle--slides', but `require'-ing orgacle-notes here would load
;; it, and run its own `add-hook' call, before this file's own
;; `add-hook' call a little further down runs -- putting notes ahead
;; of slide-in and indicators in `orgacle-page-hook' instead of after
;; them; see orgacle-notes.el for that ordering.  `declare-function'
;; only silences the byte-compiler about a call to a function it
;; cannot see yet; orgacle.el's `require' order is what actually
;; guarantees the function exists by the time this is called for
;; real.  Same idiom as orgacle-nav.el's declaration of
;; `orgacle-toggle-hide-src-blocks'.
(declare-function orgacle--build-notes-buffer "orgacle-notes" ())

(defun orgacle-refresh ()
  "Rebuild the slide vector, then delete overlays and re-fontify.
Bound to r, g, and to the key that exits `orgacle-edit-text', and
added to `org-babel-after-execute-hook' -- all points where the
presenter may just have edited the outline, which can move, add,
remove or hide a slide out from under `orgacle--slides' as it stood
when the presentation started (or since the last refresh).  Without
rebuilding here, a stale vector entry can go on pointing at a heading
that no longer qualifies as a slide -- for example one just given an
ORGACLE_HIDE property, or one whose marker collapsed onto a different
heading because the slide it used to identify was deleted -- so later
navigation would display it anyway, with no error to say so.
Re-derives `orgacle--slide-index' from point via
`orgacle--slide-index-at-point' rather than leaving it at its
pre-refresh value, so the presenter stays on the slide they were
actually looking at even when the edit changed how many slides come
before it; `orgacle--sync-page-number' keeps `orgacle-page-number' in
step with that, including the empty-deck case.

Also rebuilds a live notes buffer via `orgacle--build-notes-buffer'.
Without that, `orgacle--notes-markers' would go on pointing at the
deck as it stood when the notes buffer was last built: inserting a
slide before the current one and refreshing would then leave the
re-derived `orgacle--slide-index' indexing the *old*, now-misaligned
marker vector, so the next navigation would show the wrong slide's
notes -- silently, since the guard in `orgacle-position-notes' only
catches an index that runs past the end of the vector, not one that
is merely pointing at a different slide within it."
  (interactive)
  (setq orgacle--slides (orgacle--build-slides))
  (setq orgacle--slide-index (orgacle--slide-index-at-point))
  (orgacle--sync-page-number)
  (when (buffer-live-p orgacle-notes-buffer)
    (orgacle--build-notes-buffer))
  (orgacle-clean-overlays (point-min) (point-max))
  (orgacle-fontify))

;; Joins `orgacle-page-hook' at load time.  orgacle.el requires this
;; file before orgacle-media.el, so `orgacle-show-file-auto' is not
;; registered yet: this call has nothing to order itself against, and
;; it does not matter whether it prepends or appends.  See
;; orgacle-media.el for how the rest of the sequence is kept in the
;; order `orgacle-current-page' used to call these functions in.
(add-hook 'orgacle-page-hook #'orgacle-slide-in-effect)

(provide 'orgacle-fontify)
;;; orgacle-fontify.el ends here

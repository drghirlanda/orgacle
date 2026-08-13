;;; orgacle-core.el --- Shared state and helpers for Orgacle  -*- lexical-binding: t; -*-

;; This file is part of Orgacle.  See orgacle.el for the package header,
;; copyright and licence.

;;; Commentary:

;; The leaf module: the customization surface, the state a running
;; presentation keeps, the compatibility shims, and the helpers every other
;; module needs.  It requires nothing from the rest of the package, so the
;; feature modules can depend on it without a cycle.

;;; Code:

(require 'org)
(require 'cl-lib)

;;; Compatibility

;; Org 9.8 renamed the inline-image API to org-link-preview-*.  The floor
;; for this package is Org 9.6, so both spellings have to be reachable.

(defun orgacle--link-preview-refresh ()
  "Regenerate the inline image previews in the current buffer."
  (if (fboundp 'org-link-preview-refresh)
      (org-link-preview-refresh)
    (with-no-warnings (org-redisplay-inline-images))))

(defun orgacle--link-preview-clear ()
  "Remove the inline image previews from the current buffer."
  (if (fboundp 'org-link-preview-clear)
      (org-link-preview-clear)
    (with-no-warnings (org-remove-inline-images))))

;; These exist only on X11 builds, where term/x-win.el defines them.  A
;; value-less `defvar' only quiets the byte-compiler within the file it
;; appears in -- unlike a `defvar' with a value, it has no effect at
;; load time and does not carry to a file that merely requires this
;; one -- so any other file that sets one of these needs its own copy
;; of the relevant line (see orgacle.el, which sets two of the four).
;; The `boundp' guards at each use site are what decide anything at
;; runtime.
(defvar x-pointer-dot)
(defvar x-pointer-shape)
(defvar x-pointer-invisible)
(defvar x-sensitive-text-pointer-shape)

(defgroup orgacle nil
  "This is a presentation mode for Emacs."
  :group 'orgacle)

(defface orgacle-title-face
  '((t :weight bold :height 360 :underline t :inherit variable-pitch))
  "Face used for the title of the document during the presentation."
  :group 'orgacle)
(defface orgacle-heading-face
  '((t :weight bold :height 270 :underline t :inherit variable-pitch))
  "Face used for the top-level headings in the outline during the presentation."
  :group 'orgacle)
(defface orgacle-subheading-face
  '((t :weight bold :height 240 :inherit variable-pitch))
  "Face used for any non-top-level headings in the outline during the presentation."
  :group 'orgacle)
(defface orgacle-author-face
  '((t :height 1.6 :inherit variable-pitch))
  "Face used for the author of the document during the presentation."
  :group 'orgacle)
(defface orgacle-bullet-face
  '((t :weight bold :height 1.4 :underline nil :inherit variable-pitch))
  "Face used for bullets during the presentation."
  :group 'orgacle)
(defface orgacle-hidden-face
  '((t))
  "Unused; hiding is done with the `invisible' text property instead.
`:invisible' was never a real face attribute, and current Emacs
rejects it at compile time.  This face is not applied anywhere in the
file; it is kept only because removing it would be a public API
change, which is out of scope here."
  :group 'orgacle)

(defcustom orgacle-indicators t
  "Whether to display fringe indicators for extra content on a slide.
When non-nil, a black square appears in the right fringe if the
current page has an ORGACLE_SHOW_FILE property, and an empty square
if it has an ORGACLE_SHOW_VIDEO property.  When showing PDF files,
an arrow in the right fringe indicates that there are more pages to
show."
  :type 'boolean
  :group 'orgacle)

(defcustom orgacle-slide-in nil
  "Whether to apply a slide-in effect when changing slides, by default.
A heading's ORGACLE_SLIDE_IN property overrides this default for that
one slide: a value of \\='no\\=', \\='nil\\=' or \\='off\\=' turns the
animation off, and any other value turns it on, regardless of this
variable's setting.  See `orgacle--slide-in-p'."
  :type 'boolean
  :group 'orgacle)

(defcustom orgacle-slide-in-lines 10
  "Number of lines below the header used for the slide-in animation.
Only relevant when `orgacle-slide-in' is enabled."
  :type 'number
  :group 'orgacle)

(defcustom orgacle-slide-in-duration 0.250
  "When slide-in is used, duration of the effect, in seconds."
  :type 'number
  :group 'orgacle)

(defcustom orgacle-slide-in-pause 1
  "Pause after changing slide, before the slide-in kicks in."
  :type 'number
  :group 'orgacle)

(defcustom orgacle-text-scale 400
  "Height for the text size when presenting."
  :type 'number
  :group 'orgacle)

(defcustom orgacle-format-latex-scale 4
  "A scaling factor for the size of the images generated from LaTeX."
  :type 'number
  :group 'orgacle)

(defcustom orgacle-hide-todos t
  "Whether or not to hide TODOs during the presentation."
  :type 'boolean
  :group 'orgacle)

(defcustom orgacle-hide-tags t
  "Whether or not to hide tags during the presentation."
  :type 'boolean
  :group 'orgacle)

(defcustom orgacle-hide-properties t
  "Whether or not to hide properties during the presentation."
  :type 'boolean
  :group 'orgacle)

(defcustom orgacle-mode-line '(:eval (int-to-string orgacle-page-number))
  "Mode-line construct to use during the presentation, or nil to hide it."
  :type 'sexp
  :group 'orgacle)

(defcustom orgacle-src-blocks-visible t
  "If non-nil source blocks are initially visible on slide change.
If nil then source blocks are initially hidden on slide change."
  :type 'boolean
  :group 'orgacle)

(defcustom orgacle-use-org-superstar t
  "Whether to prettify bullets with `org-superstar-mode'.
Has no effect when the `org-superstar' package is not installed."
  :type 'boolean
  :group 'orgacle)

(defcustom orgacle-start-presentation-hook nil
  "Hook run after starting a presentation."
  :type 'hook
  :group 'orgacle)

(defcustom orgacle-stop-presentation-hook nil
  "Hook run before stopping a presentation."
  :type 'hook
  :group 'orgacle)

(defcustom orgacle-x-pointer-shape (and (boundp 'x-pointer-dot) x-pointer-dot)
  "Shape of the mouse pointer during the presentation.
The value is one of the `x-pointer-' constants, which are integers, or
nil to leave the pointer unchanged.  Those constants exist only on X11
builds, so this is nil elsewhere."
  :type '(choice (const :tag "Leave unchanged" nil) integer)
  :group 'orgacle)

(defcustom orgacle-tooltip-mode nil
  "Whether tooltips are shown during the presentation."
  :type 'boolean
  :group 'orgacle)

(defcustom orgacle-internal-border-width 50
  "Border width, in pixels, around the presented material.
NOT WORKING: nothing in this file currently reads this variable, so
changing it has no effect."
  :type 'integer
  :group 'orgacle)

(defcustom orgacle-speaker-notes t
  "Whether to collect speaker notes into an *Orgacle Notes* buffer.
The buffer is shown in its own frame, which can be moved to a second
screen, and follows the slide being presented."
  :type 'boolean
  :group 'orgacle)

(defcustom orgacle-wpm 150
  "Words-per-minute factor used to estimate a presentation's speaking time."
  :type 'integer
  :group 'orgacle)

(defcustom orgacle-video-player "mplayer"
  "Program used to play videos; see `orgacle-show-video'.
Supported players are \"mplayer\" and \"vlc\"."
  :type 'string
  :group 'orgacle)

(defvar orgacle--frame nil
  "Frame for Orgacle.")

(defvar orgacle--org-buffer nil
  "Original Org-mode buffer.")

(defvar orgacle--org-restriction nil
  "Original restriction in Org-mode buffer.")

(defvar orgacle--org-file nil
  "Temporary Org-mode file used when a narrowed region.")

(defconst orgacle-saved-variables
  '(org-src-fontify-natively
    org-hide-emphasis-markers
    org-pretty-entities
    org-fontify-quote-and-verse-blocks)
  "Variables Orgacle changes while presenting and restores on quit.
Adding one here is enough; both directions are handled by
`orgacle--save-user-state' and `orgacle--restore-user-state'.")

(defvar orgacle--saved-state nil
  "Alist of (SYMBOL . VALUE) captured by `orgacle--save-user-state'.
Also doubles as the \"is a save already pending\" flag that function
tests before it does anything, so its own value is what makes the
guard live again once `orgacle--restore-user-state' clears it back to
nil.")

(defvar orgacle-outline-ellipsis nil
  "The `selective-display' display-table slot, saved while presenting.
This holds a display-table value, not an ordinary variable, so it is
saved and restored directly with `display-table-slot' and
`set-display-table-slot' rather than through `orgacle-saved-variables';
see `orgacle--save-user-state', which guards it the same way.")

(defun orgacle--save-user-state ()
  "Record the user's state, once, until it is restored.
Captures the current value of every variable in
`orgacle-saved-variables', plus the outline-ellipsis display-table
slot into `orgacle-outline-ellipsis' -- the latter cannot join that
list because it is a display-table slot, not a variable, but it needs
the same protection, so this function owns both.

A no-op when a save is already pending: `orgacle-mode' calls this
unconditionally on every entry, and entering it a second time with no
intervening `orgacle-quit' -- for example because the presentation
frame was killed with the window manager instead of `q', or because
`orgacle-run' was invoked from a second Org buffer, which only checks
the *current* buffer's major mode -- must not let the second entry's
save overwrite the user's original values with the presentation's own.
The first save wins; `orgacle--restore-user-state' is what clears
`orgacle--saved-state' back to nil, making the guard live again for the
next genuine entry.

`standard-display-table' is nil until something creates it, which the
autoloaded `disp-table.el' normally does as a side effect of its own
loading; under byte-compiled evaluation that has not always happened
yet, so this vivifies it directly first, using the same idiom
`disp-table.el' itself uses."
  (unless orgacle--saved-state
    (setq orgacle--saved-state
          (mapcar (lambda (sym) (cons sym (symbol-value sym)))
                  orgacle-saved-variables))
    (unless (char-table-p standard-display-table)
      (setq standard-display-table (make-display-table)))
    (setq orgacle-outline-ellipsis
          (display-table-slot standard-display-table 'selective-display))))

(defun orgacle--restore-user-state ()
  "Put every variable saved by `orgacle--save-user-state' back.
Does nothing when nothing has been saved, so it is safe to call even
when no presentation is running."
  (dolist (entry orgacle--saved-state)
    (set (car entry) (cdr entry)))
  (setq orgacle--saved-state nil))

(defvar orgacle-overlays nil)
(defvar orgacle-fringe-overlays nil)
(defvar orgacle-aux-fringe-overlay nil)
(defvar orgacle-page-number 0
  "Number of the slide currently on display, counting from 1.
Always kept equal to `orgacle--slide-index' plus one; the mode line
reads this variable, and a user may too, which is why it stays a
variable of its own instead of being computed on every read.
`orgacle--goto-slide' is the only place that sets it.")
(defvar orgacle--slides nil
  "Vector of markers built by `orgacle--build-slides', one per slide.
Set once per presentation by `orgacle--start-slides'; navigation is
then index arithmetic over this vector.")
(defvar orgacle--slide-index 0
  "Index into `orgacle--slides' of the slide currently on display.
Zero-based; `orgacle-page-number' is always this plus one.")
(defvar orgacle--notes-markers nil
  "Vector of markers into `orgacle-notes-buffer', one per slide.
Built by `orgacle--build-notes-buffer' in the same order as
`orgacle--slides', so `orgacle-position-notes' can jump to a slide's
notes by `orgacle--slide-index' instead of searching for its heading
text.  Nil when there is no notes buffer, and possibly shorter than
`orgacle--slides' after `orgacle-refresh' rebuilds the latter without
rebuilding the notes buffer; `orgacle-position-notes' guards both
cases.")
(defvar orgacle-user-x-pointer-shape nil)
(defvar orgacle-user-x-sensitive-text-pointer-shape nil)

(defvar orgacle-mouse-visible t
  "Whether the mouse pointer is currently visible.
`orgacle-toggle-mouse' reads this, but nothing in this file ever sets
it back to nil, so the toggle is currently one-way: it only ever hides
the pointer.  P3 owns making this variable track the pointer's actual
state.")

(defvar orgacle-frame-level 1)

(defvar orgacle-notes-buffer nil)

(defvar orgacle-src-block-toggle-state nil)

(defvar orgacle-show-filename nil
  "Filename shown in the auxiliary window.
See `orgacle-show-file'.")

(defvar orgacle-aux-window nil
  "Auxiliary window for showing files.  See `orgacle-show-file'.")

(defvar orgacle-presentation-window nil
  "The Orgacle presentation window.")

(defvar orgacle-show-buffer nil)

(defvar orgacle--pdf-tools-warned nil
  "Non-nil once `orgacle-show-file' has warned that pdf-tools is absent.
Keeps that warning to once per session instead of once per slide.")

(defun orgacle-get-frame-level ()
  "Get the heading level to show as different frames."
  (interactive)
  (save-excursion
    (save-restriction
      (widen)
      (goto-char (point-min))
      (if (re-search-forward
           "^#\\+ORGACLE_FRAME_LEVEL:[ \t]*\\(.*?\\)[ \t]*$" nil t)
          (string-to-number (match-string 1))
        orgacle-frame-level))))

(defun orgacle-get-mode-line ()
  "Get the presentation-specific mode-line."
  (interactive)
  (save-excursion
    (save-restriction
      (widen)
      (goto-char (point-min))
      (if (re-search-forward
           "^#\\+ORGACLE_MODE_LINE:[ \t]*\\(.*?\\)[ \t]*$" nil t)
          (car (read-from-string (match-string 1)))
        orgacle-mode-line))))

(defun orgacle--slide-p ()
  "Return non-nil when point is on a heading that is its own slide.
A slide is a heading at `orgacle-frame-level' that is not a title
page, not a speaker-notes subtree, and does not carry ORGACLE_HIDE."
  (and (org-at-heading-p)
       (= (org-reduced-level (org-current-level)) orgacle-frame-level)
       (not (org-entry-get nil "ORGACLE_HIDE"))
       (let ((title (downcase (or (org-entry-get nil "ITEM") ""))))
         (not (member title '("title page" "speaker notes"))))))

(defun orgacle--build-slides ()
  "Return a vector of markers, one per slide, in buffer order.
Works on the whole buffer even when called with the buffer narrowed
to a single slide, which is the state during a presentation.

Each marker has insertion type t (advancing), the same choice
`org-agenda-new-marker' makes for markers that identify a heading: a
marker at a heading's bol is exactly the position where a new sibling
heading gets inserted -- for example \\='M-RET\\=' at the start of a
heading line, which prepends a new heading text ending in a newline
right there.  A non-advancing marker (the default) would stay behind,
now pointing at that newly-inserted heading instead of the one it was
built for; an advancing marker moves forward with its own heading's
text and keeps pointing at it."
  (let (slides)
    (save-excursion
      (save-restriction
        (widen)
        (goto-char (point-min))
        (while (re-search-forward org-outline-regexp-bol nil t)
          (beginning-of-line)
          (when (orgacle--slide-p)
            (push (copy-marker (point) t) slides))
          (end-of-line))))
    (vconcat (nreverse slides))))

(defun orgacle--slide-index-at-point (&optional pos)
  "Return the index into `orgacle--slides' of the slide at or before POS.
POS defaults to point.  Used to re-derive `orgacle--slide-index' after
an edit may have changed which headings are slides -- adding or
removing a heading, or changing whether an existing one qualifies as
`orgacle--slide-p' -- so that navigation reflects where point actually
is rather than a position recorded before the edit.  Returns 0 when
POS precedes every slide, or when `orgacle--slides' is empty (in the
latter case the return value is meaningless; callers must check
emptiness separately, the same way `orgacle--goto-slide' does)."
  (let ((pos (or pos (point))) (index 0))
    (dotimes (i (length orgacle--slides))
      (when (<= (aref orgacle--slides i) pos)
        (setq index i)))
    index))

(defun orgacle--sync-page-number ()
  "Set `orgacle-page-number' from `orgacle--slide-index'.
Zero when `orgacle--slides' is empty, since there is then no page to
number; the index plus one otherwise.  This is the only place that
computes `orgacle-page-number', so every caller that changes
`orgacle--slide-index' -- or rebuilds `orgacle--slides' out from under
it, as `orgacle-refresh' does -- gets a consistent page number without
having to remember the empty-deck special case itself."
  (setq orgacle-page-number
        (if (> (length orgacle--slides) 0) (1+ orgacle--slide-index) 0)))

(defun orgacle--get-frame ()
  "Create and set up the Orgacle frame."
  (unless (frame-live-p orgacle--frame)
    (setq orgacle--frame (make-frame '((minibuffer . nil)
                                        (title . "Orgacle")
                                        (fullscreen . fullboth)
                                        (menu-bar-lines . 0)
                                        (tool-bar-lines . 0)
                                        (vertical-scroll-bars . nil)
                                        (left-fringe . 0)
					(right-fringe . 40)
					(right-divider-width . 0)
                                        (cursor-type . nil)
					(internal-border-width . 75)))))
  (raise-frame orgacle--frame)
  (select-frame-set-input-focus orgacle--frame)
  ;; set fringe background to same as frame background
  (set-face-background 'fringe (cdr (assoc 'background-color (frame-parameters))))
  ;; set mouse pointer shape, saving the user's setting first
  (when (boundp 'x-pointer-shape)
    (setq orgacle-user-x-pointer-shape x-pointer-shape)
    (setq orgacle-user-x-sensitive-text-pointer-shape
          x-sensitive-text-pointer-shape)
    (setq x-pointer-shape orgacle-x-pointer-shape)
    (setq x-sensitive-text-pointer-shape orgacle-x-pointer-shape)
    (setq void-text-area-pointer 'text)
    ;; setting the mouse colour to its current value applies the shapes
    (set-mouse-color (cdr (assoc 'mouse-color (frame-parameters)))))
  orgacle--frame)

(defun orgacle-toggle-mouse ()
  "Show or hide the mouse pointer.
Does nothing on a build without X11 pointer support."
  (interactive)
  (when (boundp 'x-pointer-shape)
    (if orgacle-mouse-visible
        (setq x-pointer-shape x-pointer-invisible
              x-sensitive-text-pointer-shape x-pointer-invisible)
      (setq x-pointer-shape orgacle-x-pointer-shape
            x-sensitive-text-pointer-shape orgacle-x-pointer-shape))
    (setq void-text-area-pointer 'text)
    ;; setting the mouse colour to its current value applies the shapes
    (set-mouse-color (cdr (assoc 'mouse-color (frame-parameters))))))

(defun orgacle-clean-overlays (&optional start end)
  "Delete the overlays in `orgacle-overlays' contained in START..END.
An overlay that starts before START or ends after END is kept rather
than deleted.  With START and END both nil, every overlay in
`orgacle-overlays' is deleted."
  (interactive)
  (let (kept)
    (dolist (ov orgacle-overlays)
      (if (or (and start (overlay-start ov) (<= (overlay-start ov) start))
              (and end   (overlay-end   ov) (>= (overlay-end   ov) end)))
          (push ov kept)
        (delete-overlay ov)))
    (setq orgacle-overlays kept)))

(defun orgacle-clean-fringe-overlays ()
  "Remove file and video indicators from fringe."
  (interactive)
  (dolist (ov orgacle-fringe-overlays)
    (delete-overlay ov))
  (setq orgacle-fringe-overlays nil))

(defvar orgacle-page-hook nil
  "Hook run after a slide has been displayed and narrowed.
Each feature module adds its own function here, so that displaying a
slide does not have to know which subsystems exist.  A member takes no
arguments.  Order is significant: file-before-indicators is the
invariant that matters, because `orgacle-show-file' clears the fringe
overlays that `orgacle-show-indicators-maybe' draws, so running them
the other way round loses the indicators; see the `add-hook' calls in
orgacle-fontify.el, orgacle-media.el and orgacle-notes.el for how the
full default order is kept.  Members run wrapped in
`save-current-buffer', `save-selected-window' and a `condition-case':
a member may freely change the current buffer or selected window (for
example to visit a file in another window), but on both success and
failure the next member sees the buffer and window this one started
with; a failure is logged and does not stop the remaining members,
because nothing should be able to end a presentation mid-talk.")

(defun orgacle--run-page-hook ()
  "Run `orgacle-page-hook', surviving a member that signals.
Uses `run-hook-wrapped' rather than `dolist': a plain `dolist' over the
hook variable mishandles the two other ways a hook value is normally
allowed to look besides a flat list of global functions.  A
buffer-local value added with the LOCAL argument of `add-hook' ends
with a trailing sentinel meaning \"also run the global value\";
`dolist' has no notion of that sentinel, so it tries to `funcall' it
and the global members are never reached.  A hook whose
value is a single function symbol, not a list, makes `dolist' signal
`wrong-type-argument' while walking it, before the loop body's
`condition-case' is even reached, so the error is not contained and
escapes this function instead of being logged.  `run-hook-wrapped'
is the standard primitive for exactly this shape of variable, and
handles both cases correctly.

Each member additionally runs inside `save-current-buffer' and
`save-selected-window', so that a member which changes the buffer or
selected window and then signals (for example `orgacle-show-file',
which only re-selects the presentation window on its last line)
cannot hand the wrong buffer or window to the members that run after
it.  A failing member is reported in the echo area and logged; an
anonymous function is named generically rather than `%s'-formatted,
since that would print its whole byte-code object."
  (run-hook-wrapped
   'orgacle-page-hook
   (lambda (fn)
     (save-current-buffer
       (save-selected-window
         (condition-case err
             (funcall fn)
           (error
            (message "Orgacle: %s failed: %s"
                     (if (symbolp fn) fn "anonymous function")
                     (error-message-string err))))))
     nil)))

(provide 'orgacle-core)
;;; orgacle-core.el ends here

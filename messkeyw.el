;;; messkeyw.el --- automatic keyword support during composition.
;; Copyright (C) 1996-2000 Free Software Foundation, Inc.

;; Author: Karl Kleinpaste <karl[YouKnowWhatGoesHere]kleinpaste[HereToo]org>
;; Keywords: mail, news, keywords

;; This file is part of GNU Emacs.

;; GNU Emacs is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 2, or (at your option)
;; any later version.

;; GNU Emacs is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs; see the file COPYING.  If not, write to the
;; Free Software Foundation, Inc., 59 Temple Place - Suite 330,
;; Boston, MA 02111-1307, USA.

;;; Commentary:

;; This provides a hookable mechanism by which to have Keywords
;; headers automatically generated based on word frequency of the
;; body.  The goal is to make it possible to score on Keywords
;; provided, of course, that Keywords gets to the overview files.

;; To make this work, all one need do is...
;; For generation during posting:
;; (add-hook 'message-send-hook 'message-keyword-insert)
;; For generation during received-mail processing:
;; (add-hook 'nnmail-prepare-incoming-message-hook 'message-auto-keyword-insert)

;; Keywords get into overviews at the server if it is capable and
;; configured to do so.  In INN, since 1.5b2, article-supplied
;; Keywords can be gotten into overviews by enabling the line
;; "Keywords:full" in overview.fmt.

;; Note as well that INN since 2.0 has been capable of doing server-
;; side keyword auto-generation, whether or not there are article-
;; supplied Keywords headers.  (Also available in 1.7, as a patch,
;; predating the integration of this code for 2.x.)  INN grinds
;; article bodies on the way through, supplying additional data
;; to overchan, thereby providing useful bits of article content
;; for scoring/killing purposes, without requiring full-body searches.

;----------------------------------------------------------------

;;; Code:

(require 'cl)

;; data bits for generator.

(defcustom message-keyword-generate-hook  nil
  "*Hook to run in `message-keyword-generate'.
If you want to dynamically set the `message-keyword-trivia-regexp'
according to language in use, you can set in in this hook.
A original copy of `message-keyword-trivia-regexp' is restored
after `message-keyword-generate'"
  :type 'hook  :group  'message)

(defcustom message-keyword-punctuation-regexp
  "[][\\~%^+!'`\"(){}<>:;,.|?=*_@$/]"
  "*Punctuation characters in need of removal."
  :type 'regexp :group 'message)

(defcustom message-keyword-whitespace-regexp "[ \t]"
  "*Whitespace characters to be turned into newlines."
  :type 'regexp :group 'message)

(defcustom message-keyword-english-trivia-regexp "^\\(.\\|..\\|[-+/0-9][-+/0-9]*\\|.*1st\\|.*2nd\\|.*3rd\\|.*[04-9]th\\|about\\|actual\\|actually\\|after\\|ago\\|all\\|already\\|also\\|always\\|among\\|and\\|any\\|anybody\\|anyhow\\|anyone\\|anywhere\\|are\\|bad\\|because\\|been\\|before\\|being\\|between\\|but\\|can\\|could\\|did\\|does\\|doing\\|done\\|dont?\\|during\\|eight\\|eighth\\|either\\|eleven\\|else\\|elsewhere\\|eve[nr]\\|every\\|everywhere\\|few\\|five\\|fifth\\|first\\|for\\|four\\|fourth\\|from\\|get\\|going\\|gone\\|good\\|got\\|had\\|has\\|have\\|having\\|he\\|her\\|here\\|hers\\|herself\\|him\\|himself\\|his\\|how\\|ill\\|into\\|its\\|ive\\|just\\|kn[eo]w\\|least\\|less\\|let\\|like\\|look\\|many\\|may\\|more\\|m[ou]st\\|much\\|myself\\|next\\|nine\\|ninth\\|not\\|now\\|off\\|one\\|only\\|onto\\|other\\|our\\|ought\\|out\\|over\\|really\\|said\\|saw\\|say\\|says\\|second\\|see\\|set\\|seven\\|seventh\\|several\\|shall\\|she\\|should\\|since\\|six\\|sixth\\|some\\|somehow\\|someone\\|something\\|somewhere\\|such\\|take\\|ten\\|tenth\\|than\\|that\\|the\\|their\\|them\\|then\\|there\\|therell\\|theres\\|these\\|they\\|thing\\|things\\|third\\|this\\|those\\|three\\|thus\\|together\\|told\\|too\\|twelve\\|two\\|under\\|upon\\|using\\|very\\|via\\|want\\|wants\\|was\\|wasnt\\|way\\|were\\|weve\\|what\\|whatever\\|when\\|where\\|wherell\\|wheres\\|whether\\|which\\|while\\|who\\|why\\|will\\|will\\|with\\|would\\|write\\|writes\\|wrote\\|yes\\|yet\\|you\\|your\\|youre\\|yourself\\)$"
  "*Trivial (therefore ignorable) words in English.  Very empirical."
  :type 'regexp :group 'message)

(defcustom message-keyword-trivia-regexp message-keyword-english-trivia-regexp
  "*General trivia regexp."
  :type 'regexp :group 'message)

(defcustom message-keyword-moodwatch-list-english
  '("fuck\\(\\|e[dr]\\|ing\\)" "\\(bull\\)?shit" "damn" "hell" "cock\\(\\|suck\\(er\\|ing\\)\\)" "cunt" "ass" "motherfuck\\(er\\|ing\\)" "tits" "bitch" "whore")
  "*Vulgar words, in English.  Requires exact matches, hence complicated regexps."
  :type '(repeat string) :group 'message)

(defcustom message-keyword-moodwatch-list message-keyword-moodwatch-list-english
  "*General vulgarity list."
  :type '(repeat string) :group 'message)

(defcustom message-keyword-moodwatch-chili-thresholds '(0 2 5 8)
  "*Threshold values, at or below which 1, 2, or 3 `chilis' are assigned.
First (of four) value MUST be zero."
  :type '(repeat integer) :group 'message)

;; data bits for interface to generator.

(defcustom message-keyword-too-few-lines-to-bother 5
  "*Number of lines below which we won't generate Keywords at all."
  :type 'integer :group 'message)

(defcustom message-keyword-far-too-many-lines 500
  "*Number of lines above which we won't generate Keywords at all."
  :type 'integer :group 'message)

(defcustom message-keyword-short-article-limit 100
  "*Number of lines below which we generate a short-count Keywords list."
  :type 'integer :group 'message)

(defcustom message-keyword-short-count 8
  "*Max number of keywords to generate for articles of length between
message-keyword-too-few-lines-to-bother and
message-keyword-short-article-limit."
  :type 'integer :group 'message)

(defcustom message-keyword-long-count 12
  "*Max number of keywords to generate for articles of length greater
than message-keyword-short-article-limit."
  :type 'integer :group 'message)

(defcustom message-keyword-interactive t
  "*Nil means just build it and insert it.  Non-nil means ask if
the result is ok.  The latter is tempered with the fact that there are
still no questions asked if there are no keywords and the message is
too short (== 2*too-few-lines)."
  :type 'boolean :group 'message)

(defcustom message-keyword-moodwatch t
  "*If you set this, then messages you write will be scanned at send
time to see if you've been too vulgar.  Vulgarity gets a `chili rating'
based on just how much vulgarity was found.  You'll get a chance to
abort if the chili rating is non-zero.  Similarly, all incoming mail
will be scanned, and assigned a `chili rating' which is dropped in an
X-Moodwatch: header.  Do with that what you wish: Score down on it?
Score UP on it?

This capability is part of the overall keyword facility, and require
that you have the appropriate hooks set to engage the keyword functions.

Concept based on Eudora's `moodwatch' facility, implemented trivially."
  :type 'boolean :group 'message)

;----------------------------------------------------------------

(defun message-keyword-generate (maxkeys text &optional moodwatch)
  "*Generate a list of MAXKEYS keywords from the supplied TEXT.
Downcase, remove punctuation, whitespace->newline to create word list,
remove trivial words, sort, count unique occurrences > 2, ultimately
building a simple lisp list of the words."
  (save-excursion
    (let ((message-keyword-punctuation-regexp	; Make copies
	   message-keyword-punctuation-regexp)
	  (message-keyword-whitespace-regexp
	   message-keyword-whitespace-regexp)
	  (message-keyword-trivia-regexp
	   message-keyword-trivia-regexp)
	  retval
	  (count 0)
	  (word "")
	  (textbuf  (generate-new-buffer " *message-ChewableText*"))
	  (countbuf (generate-new-buffer " *message-WordCount*"))
	  pmin
	  )
      (run-hooks 'message-keyword-generate-hook)
      (if (or (not (numberp maxkeys))
	      (> maxkeys 25))			; absurdity defense.
	  (error "1st arg to keyword-generate must be an integer < 25"))
      (set-buffer textbuf)
      (insert text "\n")			; guarantee newline.
      (setq pmin (point-min))
      (downcase-region pmin (point-max))	; "tr [A-Z] [a-z]".
      (goto-char pmin)
      (while (search-forward-regexp message-keyword-punctuation-regexp nil t)
	(replace-match "\n" nil t))		; remove these chars.
      (goto-char pmin)
      (while (search-forward-regexp message-keyword-whitespace-regexp nil t)
	(replace-match "\n" nil t))		; "tr [SPC TAB] '\012'".
      (goto-char pmin)
      (while (search-forward-regexp message-keyword-trivia-regexp nil t)
	(replace-match "" nil t))		; "egrep -v '^these|words'".
      (sort-lines nil pmin (point-max))
      (goto-char pmin)
      (while (looking-at "\n")
	(delete-char 1))			; "sed -e '/^$/d'".
      ; if we're moodwatching, scan for vulgarity.
      (if moodwatch
	  (let ((mw-count 0)
		(mw-ordinal 0)
		(vulgarity message-keyword-moodwatch-list)
		vulgar
		(chilis message-keyword-moodwatch-chili-thresholds)
		chili)
	    (while (setq vulgar (car vulgarity))
	      (setq vulgarity (cdr vulgarity))
	      (goto-char pmin)
	      (while (search-forward-regexp (concat "^" vulgar "$") nil t)
		(setq mw-count (1+ mw-count))))
	    (setq mw-ordinal -1)
	    (while (and (not (listp moodwatch))
			(setq chili (car chilis)))
	      (setq chilis (cdr chilis))
	      (setq mw-ordinal (1+ mw-ordinal))
	      (if (<= mw-count chili)
		  (setq moodwatch (list mw-count mw-ordinal))))
	    (if (not chili)
		(setq moodwatch (list mw-count 9999))))
	(setq moodwatch '(0 0)))
      ; "uniq -c":
      ; while there are words to be counted...
      ;	get a word with leading ^ and newline attached.
      ;	count occurrences while deleting them (ignore counts < 3).
      (goto-char pmin)
      (while (not (eobp))
	(setq count 0
	      word (concat "^" (buffer-substring
				1 (+ 2 (skip-chars-forward "^\n")))))
	(goto-char pmin)
	(while (search-forward-regexp word nil t)
	  (replace-match "" nil t)
	  (setq count (1+ count)))
	(if (>= count 3)
	    (with-current-buffer countbuf
	      (insert (format "%5d\t%s" count word)))))
      ; in countbuf, "sort -nr".
      ; delete the counts. ("sed -e 's/^.*\t^//'")
      ; build a list with the results.
      (kill-buffer (current-buffer))
      (set-buffer countbuf)
      (setq pmin (point-min))
      (sort-lines t pmin (point-max))
      (goto-char pmin)
      (while (search-forward-regexp "^.+\t^" nil t)
	(replace-match "" nil t))
      (goto-char pmin)
      (while (and (not (eobp))
		  (> maxkeys 0))
	(setq retval (append retval
			     (list (buffer-substring
				    (point)
				    (+ (point) (skip-chars-forward "^\n"))))))
	(decf maxkeys)
	(forward-char 1))
      (kill-buffer (current-buffer))
      (list retval moodwatch)
      )
    )
  )

(defun message-keyword-chili-string (count ordinal)
  "Conjure a standard string for how to show chili rating."
  (concat (int-to-string ordinal)
	  " chili" (if (= ordinal 1) "" "s")
	  " (" (int-to-string count)
	  " occurrence" (if (= count 1) ")" "s)")))

;;;###autoload
(defun message-keyword-insert ()
  "*Take current buffer's contents and compute a Keywords header for it."
  (interactive)
  (let ((keywords "")
	keys
	(count 0)
	(string (buffer-string))
	(quickbuf (generate-new-buffer " *message-BodyOnly*"))
	chili-count chili-ordinal)
    (save-excursion
      (unless (message-fetch-field "keywords")
	(set-buffer quickbuf)
	(insert string)
	(narrow-to-region (message-goto-body)
			  (progn (message-goto-signature)
				 (point)))
	(setq count (count-lines (point-min) (point-max)))
	;; compute a string of keywords.  #keywords is based on line count.
	(setq keys (if (or
			(< count message-keyword-too-few-lines-to-bother)
			(> count message-keyword-far-too-many-lines))
		       nil
		     (message-keyword-generate
		      (if (> count message-keyword-short-article-limit)
			  message-keyword-long-count
			message-keyword-short-count)
		      (buffer-string)
		      message-keyword-moodwatch)))
	;; see if the user wants to reconsider flaming.
	(setq chili-count (caadr keys)
	      chili-ordinal (cadadr keys))
	(if (and chili-ordinal
		 (> chili-ordinal 0)
		 (not (y-or-n-p
		       (concat "Moodwatch rating: "
			       (message-keyword-chili-string
				chili-count chili-ordinal)
			       " -- continue? "))))
	    (error "Moodwatch chili rating judgment call: Aborted."))
	;; make a usable keyword list.
	(setq keywords (mapconcat 'identity (car keys) ","))
	(kill-buffer (current-buffer))))
    ;; back in *message* buffer now.
    ;; if user wants to have a hand in things, this is his chance.
    (if (and message-keyword-interactive
	     (or (not (string-equal keywords ""))
		 (> count (* 2 message-keyword-too-few-lines-to-bother))))
	(setq keywords (read-string "Keywords: " keywords)))
    ;; but one way or another, now insert the keywords.
    (if (not (string-equal keywords ""))
	(save-excursion
	  (message-goto-keywords)
	  (insert keywords)))))

;;;###autoload
(defun message-auto-keyword-insert ()
  "*Generate a Keywords header for auto-scoring purposes.  Use this with
 (add-hook 'nnmail-prepare-incoming-message-hook 'message-auto-keyword-insert)."
  (interactive)
  (save-excursion
    (let (keywords keys header-end body-start body-end line-count chili-count chili-ord)
      (goto-char (point-min))
      (setq header-end (search-forward "\n\n" nil t))
      (setq body-start (or header-end (point-min)))
      (setq header-end (or header-end (point-max)))
      (goto-char (point-max))
      (setq body-end (or (search-backward "\n-- " nil t) (point-max)))
      (setq line-count (count-lines body-start body-end))
      ;; limit our work to articles with useful size.
      (setq keys
	    (if (and (> line-count message-keyword-too-few-lines-to-bother)
		     (< line-count message-keyword-far-too-many-lines))
		 (message-keyword-generate
		  25
		  (buffer-substring body-start body-end)
		  message-keyword-moodwatch)
	      '(() (0 0))))		; empty list + chili (count,ord) list
      (setq keywords (mapconcat 'identity (car keys) ","))
      ;; add new headers as needed.
      ;; there is already a narrowed region in effect: protect it.
      ;;
      ;; if the moodwatch ordinal is nonzero, insert a fun header.
      (setq chili-count (caadr keys)
	    chili-ord (cadadr keys))
      (if (and chili-ord
	       (not (= chili-ord 0)))
	(save-restriction
	  (narrow-to-region (point-min) header-end)
	  (goto-char (point-max))
	  (backward-char 1)
	  (insert (concat
		   "X-Moodwatch: "
		   (message-keyword-chili-string chili-count chili-ord)
		   "\n"))
	  (widen)))
      ;; if we win, insert the result.
      (unless (string-equal keywords "")
	(save-restriction
	  (narrow-to-region (point-min) header-end)
	  (goto-char (point-min))
	  (if (search-forward "\nkeywords: " nil t)
	      (end-of-line)
	    (goto-char (point-min))
	    (next-line 1)		; past From_ line.
	    (insert "Keywords: \n")
	    (backward-char 1))
	  ;; either we're creating a new one, or appending to an existing one.
	  (insert (concat (if (= (current-column) 10) "" ",ÿ,") keywords))
	  (widen))))))

(provide 'messkeyw)

;;; messkeyw.el ends here

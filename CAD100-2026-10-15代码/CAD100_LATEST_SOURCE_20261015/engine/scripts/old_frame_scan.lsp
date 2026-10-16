(defun ofs:s (v / x)
  (setq x
    (cond
      ((null v) "")
      ((= (type v) 'STR) v)
      (T (vl-princ-to-string v))
    )
  )
  (vl-string-translate "\t\r\n" "   " x)
)

(defun ofs:n (v)
  (if (numberp v) (rtos v 2 8) "")
)

(defun ofs:p (v)
  (if (and (listp v) (numberp (car v)))
    (strcat
      (ofs:n (car v)) ","
      (ofs:n (cadr v)) ","
      (ofs:n (if (numberp (caddr v)) (caddr v) 0.0))
    )
    ""
  )
)

(defun ofs:replace-all (text old new / position)
  (while (setq position (vl-string-search old text))
    (setq text
      (strcat
        (substr text 1 position)
        new
        (substr text (+ position (strlen old) 1))
      )
    )
  )
  text
)

(defun ofs:strip-mtext-command (text prefix / position finish)
  (while (setq position (vl-string-search prefix text))
    (setq finish (vl-string-search ";" text position))
    (if finish
      (setq text
        (strcat
          (substr text 1 position)
          (substr text (+ finish 2))
        )
      )
      (setq text (ofs:replace-all text prefix ""))
    )
  )
  text
)

(defun ofs:text (data / plain embedded in-embedded pair code value)
  (setq plain "")
  (setq embedded "")
  (setq in-embedded nil)
  (foreach pair data
    (setq code (car pair))
    (cond
      ((and (= code 101) (= (ofs:s (cdr pair)) "Embedded Object"))
        (setq in-embedded T)
      )
      ((member code '(1 3))
        (if in-embedded
          (setq embedded (strcat embedded (ofs:s (cdr pair))))
          (setq plain (strcat plain (ofs:s (cdr pair))))
        )
      )
    )
  )
  ;; Multiline ATTRIB contains both a compatibility group-1 value and an
  ;; embedded MTEXT payload.  Embedded MTEXT is complete (including later
  ;; paragraphs), while the ordinary value can contain only the first line.
  ;; Read one representation, then remove display-only width/paragraph codes.
  (setq value (if (/= embedded "") embedded plain))
  (setq value (ofs:strip-mtext-command value "\\W"))
  (setq value (ofs:replace-all value "\\P" ""))
  value
)

(defun ofs:row (f xs / out x)
  (setq out "")
  (foreach x xs
    (setq out
      (if (= out "")
        (ofs:s x)
        (strcat out "\t" (ofs:s x))
      )
    )
  )
  (write-line out f)
)

(defun ofs:entity-row
  (f data / etype block-record block-flags xref-path xref-resolved)
  (setq etype (cdr (assoc 0 data)))
  (setq block-record
    (if (= etype "INSERT")
      (tblsearch "BLOCK" (ofs:s (cdr (assoc 2 data))))
      nil
    )
  )
  (setq block-flags
    (if (and block-record (numberp (cdr (assoc 70 block-record))))
      (cdr (assoc 70 block-record))
      0
    )
  )
  (setq xref-path
    (if (and block-record (/= 0 (logand block-flags 4)))
      (ofs:s (cdr (assoc 1 block-record)))
      ""
    )
  )
  (setq xref-resolved
    (if (= xref-path "")
      ""
      (if (findfile xref-path) "1" "0")
    )
  )
  (ofs:row f
    (list
      "ENTITY"
      etype
      (cdr (assoc 5 data))
      (cdr (assoc 330 data))
      (cdr (assoc 410 data))
      (if (= etype "INSERT") (cdr (assoc 2 data)) "")
      (if (member etype '("ATTRIB" "TEXT" "MTEXT")) (ofs:text data) "")
      (if (= etype "ATTRIB") (cdr (assoc 2 data)) "")
      (ofs:p (cdr (assoc 10 data)))
      (ofs:n (cdr (assoc 41 data)))
      (ofs:n (cdr (assoc 42 data)))
      (ofs:n (cdr (assoc 50 data)))
      (cdr (assoc 8 data))
      (cdr (assoc 70 data))
      xref-path
      xref-resolved
      (ofs:n (cdr (assoc 40 data)))
      (ofs:n (cdr (assoc 41 data)))
      (ofs:p (cdr (assoc 11 data)))
      (cdr (assoc 72 data))
      (cdr (assoc 74 data))
      (cdr (assoc 7 data))
    )
  )
)

(defun ofs:write-insert (f insert / data next child-data child-type)
  (setq data (entget insert))
  (ofs:entity-row f data)
  ;; DXF group 66=1 means this INSERT owns a following ATTRIB/SEQEND chain.
  ;; Write only that chain; block-definition records are not part of the
  ;; top-level drawing inventory.
  (if (= (cdr (assoc 66 data)) 1)
    (progn
      (setq next (entnext insert))
      (while next
        (setq child-data (entget next))
        (setq child-type (cdr (assoc 0 child-data)))
        (if (member child-type '("ATTRIB" "SEQEND"))
          (ofs:entity-row f child-data)
        )
        (if (= child-type "SEQEND")
          (setq next nil)
          (setq next (entnext next))
        )
      )
    )
  )
)

(defun ofs:write-top-level (f entity layout / data etype)
  (setq data (entget entity))
  (if data
    (progn
      (setq etype (cdr (assoc 0 data)))
      (cond
        ((= etype "INSERT")
          (ofs:write-insert f entity)
        )
        ((and
            (member etype '("TEXT" "MTEXT" "LINE"))
            (/= (strcase layout) "MODEL"))
          (ofs:entity-row f data)
        )
      )
    )
  )
)

(defun ofs:scan-layouts
  (f / names name previous-tab selection all index entity data found-name)
  ;; AutoCAD 2020 can return an incomplete model-space result from one
  ;; database-wide (ssget "_X") query after another command has traversed
  ;; several layouts.  Activate and query each discovered tab separately so
  ;; model space and all paper-space layouts are loaded and enumerated.
  (setq previous-tab (getvar "CTAB"))
  (setq names (list "Model"))
  ;; AutoCAD Core 2020 does not expose LAYOUTLIST in every installation.
  ;; Use the first database-wide selection only to discover layout names;
  ;; completeness is obtained below from one fresh selection per tab.
  (setq all (ssget "_X" '((0 . "INSERT,TEXT,MTEXT,LINE"))))
  (if all
    (progn
      (setq index 0)
      (while (< index (sslength all))
        (setq data (entget (ssname all index)))
        (setq found-name (ofs:s (cdr (assoc 410 data))))
        (if (and (/= found-name "") (not (member found-name names)))
          (setq names (append names (list found-name)))
        )
        (setq index (1+ index))
      )
    )
  )
  (foreach name names
    ;; Activating the tab first forces AutoCAD 2020 to demand-load that
    ;; layout's objects.  A separate selection per layout avoids the partial
    ;; model-space result occasionally returned by one global _X query.
    (setvar "CTAB" name)
    (setq selection
      (ssget "_X"
        (list
          (cons 0 "INSERT,TEXT,MTEXT,LINE")
          (cons 410 name)
        )
      )
    )
    (if selection
      (progn
        (setq index 0)
        (while (< index (sslength selection))
          (setq entity (ssname selection index))
          (ofs:write-top-level f entity name)
          (setq index (1+ index))
        )
      )
    )
  )
  (setvar "CTAB" previous-tab)
)

(defun c:OLDFRAMESCAN (/ out f scan-result)
  (setq out (getenv "OLD_FRAME_SCAN_OUTPUT"))
  (if (or (null out) (= out ""))
    (setq out "old_frame_scan.tsv")
  )
  (setq f (open out "w" "utf8"))
  (ofs:row f
    (list
      "kind" "entity_type" "handle" "owner" "layout" "block_name"
      "text" "tag" "insertion_point" "x_scale" "y_scale" "rotation"
      "layer" "flags" "xref_path" "xref_resolved"
      "text_height" "width_factor" "alignment_point"
      "horizontal_mode" "vertical_mode" "text_style"
    )
  )
  (ofs:row f
    (list "DRAWING" "" "" "" "" (getvar "DWGNAME") (getvar "DWGPREFIX")
      "" "" "" "" "" "" (strcat "insunits=" (itoa (getvar "INSUNITS")))
      "" ""
    )
  )
  ;; Scan top-level block references in model space and every paper-space
  ;; layout.  Paper-space TEXT/MTEXT is also recorded so diagnostics can
  ;; distinguish a genuinely blank title field from visible loose text.
  ;; Model-space annotation is intentionally excluded to keep inventories
  ;; small on large base plans.
  (setq scan-result
    (vl-catch-all-apply 'ofs:scan-layouts (list f))
  )
  (if (vl-catch-all-error-p scan-result)
    (ofs:row f
      (list
        "ERROR" "" "" "" "" ""
        (vl-catch-all-error-message scan-result)
        "" "" "" "" "" "" "" "" ""
      )
    )
  )
  (close f)
  (princ (strcat "\nOLD_FRAME_SCAN_COMPLETE|" out))
  (princ)
)

(princ)

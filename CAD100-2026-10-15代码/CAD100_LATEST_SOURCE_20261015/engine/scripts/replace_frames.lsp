(vl-load-com)
(setq fra:last-signature-error "")
(setq fra:block-extents-cache '())
(setq fra:preserved-block-cache '())
(setq fra:xref-signature-cache '())
(setq fra:title-import-cache '())
(setq fra:title-import-directory nil)
(setq fra:last-frame-insert-error "")

(defun fra:get (code data)
  (cdr (assoc code data))
)

(defun fra:s (v / x)
  (setq x
    (cond
      ((null v) "")
      ((= (type v) 'STR) v)
      (T (vl-princ-to-string v))
    )
  )
  (vl-string-translate "\t\r\n" "   " x)
)

(defun fra:n (v)
  (if (numberp v) (rtos v 2 8) "")
)

(defun fra:p (v)
  (if (and (listp v) (numberp (car v)))
    (strcat
      (fra:n (car v)) ","
      (fra:n (cadr v)) ","
      (fra:n (if (numberp (caddr v)) (caddr v) 0.0))
    )
    ""
  )
)

(defun fra:ms-diff (finish start)
  (if (< finish start)
    (+ (- 2147483647 start) finish 1)
    (- finish start)
  )
)

(defun fra:env (name fallback / value)
  (setq value (getenv name))
  (if (or (null value) (= value "")) fallback value)
)

(defun fra:editable-tags ()
  '(
    "图号" "版本号" "图别" "设计项目号"
    "N审定_T5_H3" "N审核_T5_H3" "N校对_T5_H3" "N设计_T5_H3"
    "N专业负责人（副）_T5_H3" "N专业负责人_T5_H3"
    "N执行设总_T5_H3" "N设计总负责人_T5_H3"
    "比例" "单位" "图名" "建设单位" "设计项目名" "子项名称"
    "N执行设总二_T5_H3"
    "N设计总负责人_T6_H6" "N执行设总_T6_H6"
    "N执行设总二_T6_H6" "N专业负责人_T6_H6"
    "N专业负责人（副）_T6_H8" "N设计_T6_H6"
    "N校对_T6_H6" "N审核_T6_H6" "N审定_T6_H6"
    "N专业负责人（副）二_T5_H3" "N专业负责人（副）二_T6_H8"
    "日期" "是否会签" "图纸类别"
  )
)

(defun fra:signature-specs ()
  '(
    ("签字图块_审定" . "N审定_T6_H6")
    ("签字图块_审核" . "N审核_T6_H6")
    ("签字图块_校对" . "N校对_T6_H6")
    ("签字图块_设计" . "N设计_T6_H6")
    ("签字图块_专业负责人副二" . "N专业负责人（副）二_T6_H8")
    ("签字图块_专业负责人副" . "N专业负责人（副）_T6_H8")
    ("签字图块_专业负责人" . "N专业负责人_T6_H6")
    ("签字图块_执行设总二" . "N执行设总二_T6_H6")
    ("签字图块_执行设总" . "N执行设总_T6_H6")
    ("签字图块_设计总负责人" . "N设计总负责人_T6_H6")
  )
)

(defun fra:split-tabs (text / out pos)
  (setq out '())
  (while (setq pos (vl-string-search "\t" text))
    (setq out (cons (substr text 1 pos) out))
    (setq text (substr text (+ pos 2)))
  )
  (reverse (cons text out))
)

(defun fra:zip-pairs (tags fields / out)
  (setq out '())
  (while tags
    (setq out
      (cons
        (cons (car tags) (if fields (car fields) ""))
        out
      )
    )
    (setq tags (cdr tags))
    (if fields (setq fields (cdr fields)))
  )
  (reverse out)
)

(defun fra:load-sheet-values (path / f header tags rows line fields key)
  (setq rows '())
  (if (and (/= path "") (findfile path))
    (progn
      (setq f (open path "r" "utf8"))
      (setq header (if f (fra:split-tabs (read-line f)) nil))
      (setq tags (if header (cddr header) nil))
      (while (and f (setq line (read-line f)))
        (setq fields (fra:split-tabs line))
        (if (>= (length fields) 2)
          (progn
            (setq key
              (strcase (strcat (car fields) "|" (cadr fields)))
            )
            (setq rows
              (cons
                (cons key (fra:zip-pairs tags (cddr fields)))
                rows
              )
            )
          )
        )
      )
      (if f (close f))
    )
  )
  rows
)

(defun fra:source-drawing-name (drawing / upper)
  (setq upper (strcase drawing))
  (cond
    ((wcmatch upper "*_换框.DWG")
      (vl-string-subst ".dwg" "_换框.dwg" drawing)
    )
    ((wcmatch upper "*_图签更新.DWG")
      (vl-string-subst ".dwg" "_图签更新.dwg" drawing)
    )
    (T drawing)
  )
)

(defun fra:personnel-tag-p (tag)
  (and
    (> (strlen tag) 0)
    (= (strcase (substr tag 1 1)) "N")
  )
)

(defun fra:personnel-name-tag-p (tag)
  (member tag
    '("N审定_T5_H3" "N审核_T5_H3" "N校对_T5_H3" "N设计_T5_H3"
      "N专业负责人（副）二_T5_H3" "N专业负责人（副）_T5_H3"
      "N专业负责人_T5_H3" "N执行设总二_T5_H3"
      "N执行设总_T5_H3" "N设计总负责人_T5_H3"))
)

(defun fra:apply-overrides
  (values rows drawing handle / key found pair existing value personnel)
  (setq drawing (fra:source-drawing-name drawing))
  (setq key (strcase (strcat drawing "|" handle)))
  (setq found (assoc key rows))
  (if found
    (foreach pair (cdr found)
      (setq value (fra:s (cdr pair)))
      (setq personnel (fra:personnel-tag-p (car pair)))
      (cond
        ;; An empty personnel cell means the user did not provide a new
        ;; value, so keep the value scanned from the original title block.
        ((and personnel (= value "")) nil)
        ;; The visible marker is the deliberate way to remove a name.
        ((and personnel (= value "[清空]"))
          (setq pair (cons (car pair) ""))
          (setq existing (assoc (car pair) values))
          (if existing
            (setq values (subst pair existing values))
            (setq values (cons pair values))
          )
          (if (fra:personnel-name-tag-p (car pair))
            (setq values
              (fra:put-value values
                (strcat "__CFR_VISIBLE_" (car pair)) "0"))
          )
        )
        (T
          (setq existing (assoc (car pair) values))
          (if existing
            (setq values (subst pair existing values))
            (setq values (cons pair values))
          )
          (if (and personnel (fra:personnel-name-tag-p (car pair)))
            (setq values
              (fra:put-value values
                (strcat "__CFR_VISIBLE_" (car pair)) "1"))
          )
        )
      )
    )
  )
  values
)

(defun fra:clear-signature-attributes
  (values / spec path tag existing pair)
  (foreach spec (fra:signature-specs)
    (setq path (fra:aval (car spec) values))
    ;; A blank signature column means "preserve the original".  Any explicit
    ;; action (replacement DWG or clear sentinel) clears the old right-hand
    ;; text anchor; the sentinel also prevents old signature graphics from
    ;; being embedded.
    (if
      (/= path "")
      (progn
        (setq tag (cdr spec))
        (setq pair (cons tag ""))
        (setq existing (assoc tag values))
        (if existing
          (setq values (subst pair existing values))
          (setq values (cons pair values))
        )
      )
    )
  )
  values
)

(defun fra:values-for-tags (tags values / out tag)
  (setq out '())
  (foreach tag tags
    (setq out (cons (fra:aval tag values) out))
  )
  (reverse out)
)

(defun fra:put-value (values tag value / pair existing)
  (setq pair (cons tag (fra:s value)))
  (setq existing (assoc tag values))
  (if existing
    (subst pair existing values)
    (cons pair values)
  )
)

(defun fra:all-digits-p (text / index code ok)
  (setq index 1)
  (setq ok (> (strlen text) 0))
  (while (and ok (<= index (strlen text)))
    (setq code (ascii (substr text index 1)))
    (if (or (< code 48) (> code 57))
      (setq ok nil)
    )
    (setq index (1+ index))
  )
  ok
)

(defun fra:last-substring-position (needle text / start position found)
  (setq start 0)
  (setq found nil)
  (while (setq position (vl-string-search needle text start))
    (setq found position)
    (setq start (1+ position))
  )
  found
)

(defun fra:strip-file-revision-suffix (stem / position suffix stripping)
  ;; Repeated export suffixes such as _t9_t9 are common in delivered files.
  (setq stripping T)
  (while stripping
    (setq stripping nil)
    (setq position (fra:last-substring-position "_" stem))
    (if position
      (progn
        (setq suffix (substr stem (+ position 2)))
        (if
          (and
            (> (strlen suffix) 1)
            (= (strcase (substr suffix 1 1)) "T")
            (fra:all-digits-p (substr suffix 2))
          )
          (progn
            (setq stem (substr stem 1 position))
            (setq stripping T)
          )
        )
      )
    )
  )
  stem
)

(defun fra:filename-number-char-p (character / code)
  (setq code (ascii character))
  (or
    (and (>= code 48) (<= code 57))
    (and (>= code 65) (<= code 90))
    (and (>= code 97) (<= code 122))
    (member character '("-" "." "~" "#" "_"))
  )
)

(defun fra:apply-filename-fallback
  (values drawing / stem index number name)
  (setq stem
    (vl-string-trim
      " \t"
      (fra:strip-file-revision-suffix (vl-filename-base drawing))
    )
  )
  ;; Normalize the full-width wave dash before byte-wise filename parsing.
  (setq stem (fra:string-replace-all stem "～" "~"))
  (setq index 1)
  (while
    (and
      (<= index (strlen stem))
      (fra:filename-number-char-p (substr stem index 1))
    )
    (setq index (1+ index))
  )
  (setq number (vl-string-trim " \t" (substr stem 1 (1- index))))
  (setq name (vl-string-trim " \t-_" (substr stem index)))
  ;; A file-name fallback is intentionally conservative: it is used only by
  ;; callers that have exactly one detected sheet, and it never overwrites a
  ;; value actually read from the drawing.
  (if
    (and
      (/= number "")
      (/= name "")
      (vl-string-search "-" number)
    )
    (progn
      (if (= (fra:aval "图号" values) "")
        (setq values (fra:put-value values "图号" number))
      )
      (if (= (fra:aval "图名" values) "")
        (setq values (fra:put-value values "图名" name))
      )
    )
  )
  values
)

(defun fra:copy-if-empty
  (values target source oldattrs / current source-value)
  (setq current (fra:aval target values))
  (setq source-value (fra:aval source oldattrs))
  (if (and (= current "") (/= source-value ""))
    (fra:put-value values target source-value)
    values
  )
)

(defun fra:initial-values
  (oldattrs spec operation owner project-name project-date project-number
    / values tag)
  (setq values '())
  (foreach tag (append (fra:editable-tags) (list "图幅"))
    (setq values
      (fra:put-value values tag (fra:aval tag oldattrs))
    )
  )
  ;; Common legacy title tags are mapped only when the new-schema target is
  ;; empty.  Exact attribute tags always take precedence.
  (setq values (fra:copy-if-empty values "N审定_T5_H3" "批准" oldattrs))
  (setq values (fra:copy-if-empty values "N审核_T5_H3" "审核" oldattrs))
  (setq values (fra:copy-if-empty values "N校对_T5_H3" "校对" oldattrs))
  (setq values (fra:copy-if-empty values "N设计_T5_H3" "设计" oldattrs))
  (setq values
    (fra:copy-if-empty
      values "N专业负责人_T5_H3" "项目负责人" oldattrs)
  )
  ;; Empty global fields mean "preserve the drawing value".  Explicit
  ;; per-sheet TSV values, including an empty string, are applied later.
  (if (/= owner "")
    (setq values (fra:put-value values "建设单位" owner))
  )
  (if (/= project-name "")
    (setq values (fra:put-value values "设计项目名" project-name))
  )
  (if (/= project-date "")
    (setq values (fra:put-value values "日期" project-date))
  )
  (if (/= project-number "")
    (setq values (fra:put-value values "设计项目号" project-number))
  )
  (if (= operation "REPLACE")
    (progn
      (setq values
        (fra:put-value values "图幅" (fra:paper-label spec))
      )
      (if (= (fra:aval "单位" values) "")
        (setq values (fra:put-value values "单位" "见图"))
      )
    )
  )
  values
)

(defun fra:strip-mtext-command (text prefix / position finish)
  (while (setq position (vl-string-search prefix text))
    (setq finish (vl-string-search ";" text position))
    (if finish
      (setq text
        (strcat
          (substr text 1 position)
          (substr text (+ finish 2))
        )
      )
      (setq text (fra:string-replace-all text prefix ""))
    )
  )
  text
)

(defun fra:attribute-value
  (data / plain embedded in-embedded pair code value)
  (setq plain "")
  (setq embedded "")
  (setq in-embedded nil)
  (foreach pair data
    (setq code (car pair))
    (cond
      ((and (= code 101) (= (fra:s (cdr pair)) "Embedded Object"))
        (setq in-embedded T)
      )
      ((member code '(1 3))
        (if in-embedded
          (setq embedded (strcat embedded (fra:s (cdr pair))))
          (setq plain (strcat plain (fra:s (cdr pair))))
        )
      )
    )
  )
  (setq value (if (/= embedded "") embedded plain))
  (setq value (fra:strip-mtext-command value "\\W"))
  (setq value (fra:string-replace-all value "\\P" ""))
  value
)

(defun fra:visible-loose-text (data / value)
  (setq value (fra:attribute-value data))
  (foreach prefix '("\\A" "\\f" "\\F" "\\H" "\\p")
    (setq value (fra:strip-mtext-command value prefix)))
  (setq value (fra:string-replace-all value "\\L" ""))
  (setq value (fra:string-replace-all value "\\l" ""))
  (setq value (vl-string-translate "{}" "  " value))
  (vl-string-trim " " value)
)

(defun fra:attr-pairs (insert / next data pairs)
  (setq pairs '())
  (setq next (entnext insert))
  (while next
    (setq data (entget next))
    (cond
      ((= (fra:get 0 data) "ATTRIB")
        (setq pairs
          (cons
            (cons (fra:s (fra:get 2 data)) (fra:attribute-value data))
            pairs
          )
        )
      )
      ((= (fra:get 0 data) "SEQEND")
        (setq next nil)
      )
    )
    (if next (setq next (entnext next)))
  )
  (reverse pairs)
)

(defun fra:overlay-nonempty-attrs (base overlay / pair existing)
  (foreach pair overlay
    (if (/= (fra:s (cdr pair)) "")
      (progn
        (setq existing (assoc (car pair) base))
        (if existing
          (setq base (subst pair existing base))
          (setq base (cons pair base))
        )
      )
    )
  )
  base
)

(defun fra:overlay-fill-empty-attrs (base overlay / pair existing)
  ;; Supplemental detail-title fields may fill a genuinely blank main-title
  ;; field, but must never replace a value already read from the main XREF
  ;; title (especially DWG NO.).
  (foreach pair overlay
    (if (/= (fra:s (cdr pair)) "")
      (progn
        (setq existing (assoc (car pair) base))
        (if (or (null existing) (= (fra:s (cdr existing)) ""))
          (if existing
            (setq base (subst pair existing base))
            (setq base (cons pair base))
          )
        )
      )
    )
  )
  base
)

(defun fra:aval (tag pairs / found)
  (setq found (assoc tag pairs))
  (if found (cdr found) "")
)

(defun fra:title-p (entity / attrs hits)
  (setq attrs (fra:attr-pairs entity))
  (setq hits 0)
  (foreach tag '("图号" "图名" "子项名称" "日期" "比例" "图别" "版本号")
    (if (assoc tag attrs) (setq hits (1+ hits)))
  )
  (and (assoc "图号" attrs) (>= hits 3))
)

(defun fra:same-insert-transform-p (left right / ldata rdata)
  ;; Exact stacked copies are usually abandoned frame/title templates or
  ;; visibility alternatives.  Their visible intent cannot be inferred from
  ;; database geometry, so they must never outrank unique placed sheets.
  (setq ldata (entget left))
  (setq rdata (entget right))
  (and
    (= (strcase (fra:s (fra:get 2 ldata)))
       (strcase (fra:s (fra:get 2 rdata))))
    (= (strcase (fra:s (fra:get 410 ldata)))
       (strcase (fra:s (fra:get 410 rdata))))
    (equal (fra:get 10 ldata) (fra:get 10 rdata) 0.000001)
    (< (abs (- (fra:insert-scale-x ldata) (fra:insert-scale-x rdata)))
       0.000001)
    (< (abs (- (fra:insert-scale-y ldata) (fra:insert-scale-y rdata)))
       0.000001)
    (< (fra:angle-difference
         (fra:insert-rotation ldata)
         (fra:insert-rotation rdata))
       0.000001)
  )
)

(defun fra:stacked-copy-p (entity pool / found other)
  (setq found nil)
  (foreach other pool
    (if
      (and
        (not (equal entity other))
        (fra:same-insert-transform-p entity other)
      )
      (setq found T)
    )
  )
  found
)

(defun fra:frame-specs ()
  '(
    ("A2" 594.0 420.0 "NEW_FRAME_A2")
    ("A2+0.25" 743.0 420.0 "NEW_FRAME_A2P025")
    ("A2+0.5" 891.0 420.0 "NEW_FRAME_A2P05")
    ("A2+0.75" 1041.0 420.0 "NEW_FRAME_A2P075")
    ("A2+1" 1189.0 420.0 "NEW_FRAME_A2P1")
    ("A1" 841.0 594.0 "NEW_FRAME_A1")
    ("A1+0.25" 1051.0 594.0 "NEW_FRAME_A1P025")
    ("A1+0.75" 1471.75 594.0 "NEW_FRAME_A1P075")
    ("A1+1" 1682.0 594.0 "NEW_FRAME_A1P1")
    ("A0" 1189.0 841.0 "NEW_FRAME_A0")
    ("A0+0.125" 1338.0 841.0 "NEW_FRAME_A0P0125")
    ("A0+0.25" 1486.0 841.0 "NEW_FRAME_A0P025")
    ("A0+0.375" 1635.0 841.0 "NEW_FRAME_A0P0375")
    ("A0+0.5" 1783.0 841.0 "NEW_FRAME_A0P05")
  )
)

(defun fra:collect (/ selection index next data candidates titles)
  (setq candidates '())
  (setq titles '())
  (setq selection (ssget "_X" '((0 . "INSERT"))))
  (if selection
    (progn
      (setq index 0)
      (while (< index (sslength selection))
        (setq next (ssname selection index))
        (setq data (entget next))
        (if (/= (fra:s (fra:get 410 data)) "")
          (if (and (= (fra:get 66 data) 1) (fra:title-p next))
            (setq titles (cons next titles))
            (setq candidates (cons next candidates))
          )
        )
        (setq index (1+ index))
      )
    )
  )
  (setq candidates (reverse candidates))
  (setq titles (reverse titles))
  ;; Discard every member of an exact stack. Keeping even one would fabricate
  ;; a confident-looking sheet from an indeterminate set of overlapping data.
  (setq candidates
    (vl-remove-if
      '(lambda (item) (fra:stacked-copy-p item candidates))
      candidates
    )
  )
  (setq titles
    (vl-remove-if
      '(lambda (item) (fra:stacked-copy-p item titles))
      titles
    )
  )
  (list candidates titles)
)

(defun fra:distance2 (p q / dx dy)
  (setq dx (- (car p) (car q)))
  (setq dy (- (cadr p) (cadr q)))
  (+ (* dx dx) (* dy dy))
)

(defun fra:layout-name (entity)
  (fra:s (fra:get 410 (entget entity)))
)

(defun fra:insert-scale-x (data)
  (if (numberp (fra:get 41 data)) (fra:get 41 data) 1.0)
)

(defun fra:insert-scale-y (data)
  (if (numberp (fra:get 42 data)) (fra:get 42 data) 1.0)
)

(defun fra:insert-rotation (data)
  (if (numberp (fra:get 50 data)) (fra:get 50 data) 0.0)
)

(defun fra:local-title-offset
  (frame title / fdata tdata fp tp sx sy a dx dy)
  (setq fdata (entget frame))
  (setq tdata (entget title))
  (setq fp (fra:get 10 fdata))
  (setq tp (fra:get 10 tdata))
  (setq sx (fra:insert-scale-x fdata))
  (setq sy (fra:insert-scale-y fdata))
  (setq a (fra:insert-rotation fdata))
  (if (or (< (abs sx) 0.000001) (< (abs sy) 0.000001))
    nil
    (progn
      (setq dx (- (car tp) (car fp)))
      (setq dy (- (cadr tp) (cadr fp)))
      (list
        (/ (+ (* dx (cos a)) (* dy (sin a))) sx)
        (/ (+ (* (- dx) (sin a)) (* dy (cos a))) sy)
      )
    )
  )
)

(defun fra:spec-error (frame title spec / local ex ey dx dy)
  (if (/= (strcase (fra:layout-name frame)) (strcase (fra:layout-name title)))
    nil
    (progn
      (setq local (fra:local-title-offset frame title))
      (if (null local)
        nil
        (progn
          (setq ex (- (nth 1 spec) 10.0))
          (setq ey 10.0)
          (setq dx (- (car local) ex))
          (setq dy (- (cadr local) ey))
          (sqrt (+ (* dx dx) (* dy dy)))
        )
      )
    )
  )
)

(defun fra:frame-control-score (frame / attrs score pair tag)
  (setq attrs (fra:attr-pairs frame))
  (setq score 0)
  (foreach pair attrs
    (setq tag (strcase (car pair)))
    (cond
      ((= tag "LZTQINS")
        (setq score (+ score 60))
      )
      ((wcmatch tag "LZHQ_*")
        (setq score (+ score 40))
      )
    )
  )
  score
)

(defun fra:xref-p (frame / data record flags)
  (setq data (entget frame))
  (setq record (tblsearch "BLOCK" (fra:get 2 data)))
  (setq flags (if record (fra:get 70 record) 0))
  (and (numberp flags) (/= 0 (logand flags 4)))
)

(defun fra:localize-xrefs
  (/ document blocks block is-xref path extension filename local-path
    relative-path result count)
  ;; UpdateTitle keeps XREF frames.  Consultant drawings often store stale
  ;; absolute paths from another workstation.  If a same-named dependency was
  ;; copied beside the output host DWG, repath only the output host's block
  ;; record to that portable relative file.  Do not reload in the same Core
  ;; Console session: reloading consultant base plans can block headless CAD.
  ;; The independent verification session reopens the saved DWG and resolves
  ;; the new relative path.
  (setq count 0)
  (setq document (vla-get-ActiveDocument (vlax-get-acad-object)))
  (setq blocks (vla-get-Blocks document))
  (vlax-for block blocks
    (setq is-xref
      (vl-catch-all-apply 'vla-get-IsXRef (list block)))
    (if (and (not (vl-catch-all-error-p is-xref))
             (= is-xref :vlax-true))
      (progn
        (setq path (vl-catch-all-apply 'vla-get-Path (list block)))
        (if (and (not (vl-catch-all-error-p path)) (/= path ""))
          (progn
            (setq extension (vl-filename-extension path))
            (if (or (null extension) (= extension ""))
              (setq extension ".dwg")
            )
            (setq filename (strcat (vl-filename-base path) extension))
            (setq local-path (strcat (getvar "DWGPREFIX") filename))
            (if (and
                  (wcmatch (strcase filename)
                    "A0.DWG,A0+*.DWG,A1.DWG,A1+*.DWG,A2.DWG,A2+*.DWG")
                  (findfile local-path)
                )
              (progn
                (setq relative-path (strcat ".\\" filename))
                (setq result
                  (vl-catch-all-apply
                    'vla-put-Path (list block relative-path)))
                (if (not (vl-catch-all-error-p result))
                  (setq count (1+ count))
                )
              )
            )
          )
        )
      )
    )
  )
  count
)

(defun fra:title-attribute-score (attrs / score tag)
  (setq score 0)
  (foreach tag
    '("建设单位" "设计项目名" "子项名称" "日期" "设计项目号"
      "图名" "图号" "图幅" "比例" "图别" "版本号" "单位")
    (if (assoc tag attrs)
      (setq score (+ score (if (= (fra:aval tag attrs) "") 1 5)))
    )
  )
  score
)

(defun fra:personnel-row-specs ()
  '(
    ("N审定_T5_H3" 28.0)
    ("N审核_T5_H3" 36.0)
    ("N校对_T5_H3" 44.0)
    ("N设计_T5_H3" 52.0)
    ("N专业负责人（副）二_T5_H3" 60.0)
    ("N专业负责人（副）_T5_H3" 68.0)
    ("N专业负责人_T5_H3" 76.0)
    ("N执行设总二_T5_H3" 84.0)
    ("N执行设总_T5_H3" 92.0)
    ("N设计总负责人_T5_H3" 100.0)
  )
)

(defun fra:signature-row-specs ()
  '(
    ("签字图块_审定" 28.0)
    ("签字图块_审核" 36.0)
    ("签字图块_校对" 44.0)
    ("签字图块_设计" 52.0)
    ("签字图块_专业负责人副二" 60.0)
    ("签字图块_专业负责人副" 68.0)
    ("签字图块_专业负责人" 76.0)
    ("签字图块_执行设总二" 84.0)
    ("签字图块_执行设总" 92.0)
    ("签字图块_设计总负责人" 100.0)
  )
)

(defun fra:nearest-row-spec (relative-y specs / best best-distance item distance)
  (setq best nil)
  (setq best-distance nil)
  (foreach item specs
    (setq distance (abs (- relative-y (cadr item))))
    (if (or (null best-distance) (< distance best-distance))
      (progn
        (setq best item)
        (setq best-distance distance)
      )
    )
  )
  (if (and best (<= best-distance 3.0)) best nil)
)

(defun fra:xref-personnel-attrs
  (block spec origin / attrs entity data etype point width x y row text)
  (setq attrs '())
  (setq width (nth 1 spec))
  (setq entity (if block (entnext block) nil))
  (while entity
    (setq data (entget entity))
    (setq etype (fra:s (fra:get 0 data)))
    (cond
      ((= etype "ENDBLK")
        (setq entity nil)
      )
      ((member etype '("TEXT" "MTEXT"))
        (setq point (fra:get 10 data))
        (if (and point (numberp (car point)) (numberp (cadr point)))
          (progn
            (setq x (- (car point) (if origin (car origin) 0.0)))
            (setq y (- (cadr point) (if origin (cadr origin) 0.0)))
            ;; Old XREF title blocks often keep personnel names as loose
            ;; MTEXT beside the nested attribute title.  Only inspect the
            ;; middle personnel column and map by its fixed row height.
            (if
              (and
                (>= x (- width 80.0))
                (<= x (- width 30.0))
                (>= y 34.0)
                (<= y 114.0)
                (setq row
                  (fra:nearest-row-spec
                    (- y 10.0)
                    (fra:personnel-row-specs)
                  )
                )
              )
              (progn
                (setq text (fra:attribute-value data))
                (if (/= text "")
                  (setq attrs
                    (fra:put-value attrs (car row) text)
                  )
                )
              )
            )
          )
        )
      )
    )
    (if entity (setq entity (entnext entity)))
  )
  attrs
)

(defun fra:xref-title-attrs
  (frame spec / data name block entity edata attrs score best best-score
    point width error origin expected)
  (setq best '())
  (setq best-score -1)
  (setq width (nth 1 spec))
  (setq origin (fra:xref-frame-local-origin frame spec))
  (if (null origin) (setq origin '(0.0 0.0 0.0)))
  (setq expected
    (list (+ (car origin) (- width 10.0)) (+ (cadr origin) 10.0) 0.0)
  )
  (setq data (entget frame))
  (setq name (fra:s (fra:get 2 data)))
  (setq block (tblobjname "BLOCK" name))
  (if block
    (progn
      (setq entity (entnext block))
      (while entity
        (setq edata (entget entity))
        (cond
          ((= (fra:s (fra:get 0 edata)) "ENDBLK")
            (setq entity nil)
          )
          ((and
             (= (fra:s (fra:get 0 edata)) "INSERT")
             (= (fra:get 66 edata) 1)
           )
            (setq attrs (fra:attr-pairs entity))
            ;; Detail-title blocks can use the same tags as the main title.
            ;; Only the insert at the paper's fixed bottom-right title anchor
            ;; is allowed to supply shared-XREF title attributes.
            (setq point (fra:get 10 edata))
            (setq error
              (if point
                (distance point expected)
                1.0e99
              )
            )
            (if (> error 25.0) (setq attrs '()))
            (if (and (assoc "图号" attrs) (>= (length attrs) 3))
              (progn
                (setq score (fra:title-attribute-score attrs))
                (if (> score best-score)
                  (progn
                    (setq best attrs)
                    (setq best-score score)
                  )
                )
              )
            )
          )
        )
        (if entity (setq entity (entnext entity)))
      )
    )
  )
  (fra:overlay-fill-empty-attrs
    best
    (fra:xref-personnel-attrs block spec origin)
  )
)

(defun fra:frame-name-score (frame / data name score)
  (setq data (entget frame))
  (setq name (strcase (fra:s (fra:get 2 data))))
  (setq score 0)
  (if
    (wcmatch
      name
      "*FRAME*,*图框*,TK-*,A0*,A1*,A2*,*INSERTFRAME*"
    )
    (setq score (+ score 20))
  )
  (if (wcmatch name "YCT-*")
    (setq score (- score 20))
  )
  (if (fra:xref-p frame)
    (setq score (+ score 10))
  )
  score
)

(defun fra:extent-add-point
  (extents point / x y)
  (if
    (and
      (listp point)
      (numberp (car point))
      (numberp (cadr point))
    )
    (progn
      (setq x (car point))
      (setq y (cadr point))
      (if extents
        (list
          (min (nth 0 extents) x)
          (min (nth 1 extents) y)
          (max (nth 2 extents) x)
          (max (nth 3 extents) y)
        )
        (list x y x y)
      )
    )
    extents
  )
)

(defun fra:block-extents
  (frame / data name key cached block entity edata kind pair code extents)
  (setq data (entget frame))
  (setq name (fra:s (fra:get 2 data)))
  (setq key (strcase name))
  (setq cached (assoc key fra:block-extents-cache))
  (if cached
    (cdr cached)
    (progn
      (setq extents nil)
      (setq block (tblobjname "BLOCK" name))
      (if block
        (progn
          (setq entity (entnext block))
          (while entity
            (setq edata (entget entity))
            (setq kind (fra:s (fra:get 0 edata)))
            (if (= kind "ENDBLK")
              (setq entity nil)
              (progn
                (foreach pair edata
                  (setq code (car pair))
                  (if
                    (and
                      (numberp code)
                      (<= 10 code)
                      (<= code 18)
                    )
                    (setq extents
                      (fra:extent-add-point extents (cdr pair))
                    )
                  )
                )
                (setq entity (entnext entity))
              )
            )
          )
        )
      )
      (setq fra:block-extents-cache
        (cons (cons key extents) fra:block-extents-cache)
      )
      extents
    )
  )
)

(defun fra:spec-geometry-error (frame spec / extents width height dx dy)
  (setq extents (fra:block-extents frame))
  (if
    (and
      extents
      (> (- (nth 2 extents) (nth 0 extents)) 1.0)
      (> (- (nth 3 extents) (nth 1 extents)) 1.0)
    )
    (progn
      (setq width (- (nth 2 extents) (nth 0 extents)))
      (setq height (- (nth 3 extents) (nth 1 extents)))
      (setq dx (- width (nth 1 spec)))
      (setq dy (- height (nth 2 spec)))
      (sqrt (+ (* dx dx) (* dy dy)))
    )
    nil
  )
)

(defun fra:xref-frame-local-origin
  (frame spec / data block entity edata kind nested-name pattern found
    extents width height dx dy)
  ;; XREF paper files are often authored far from 0,0.  The INSERT point is
  ;; therefore not the visible border origin.  Accept the block-definition
  ;; minimum only when its extents still prove the exact requested paper
  ;; size; otherwise return nil rather than guessing a placement.
  (setq found nil)
  (setq data (entget frame))
  (setq block (tblobjname "BLOCK" (fra:s (fra:get 2 data))))
  (setq pattern
    (strcat
      "*YCT-" (itoa (fix (+ (nth 1 spec) 0.5))) "-"
      (itoa (fix (+ (nth 2 spec) 0.5))) "-*"
    )
  )
  (setq entity (if block (entnext block) nil))
  (while (and entity (null found))
    (setq edata (entget entity))
    (setq kind (fra:s (fra:get 0 edata)))
    (cond
      ((= kind "ENDBLK") (setq entity nil))
      ((= kind "INSERT")
        (setq nested-name (strcase (fra:s (fra:get 2 edata))))
        (if (wcmatch nested-name pattern)
          (setq found (fra:get 10 edata))
        )
      )
    )
    (if entity (setq entity (entnext entity)))
  )
  (if found
    found
    (progn
      (setq extents (fra:block-extents frame))
      (if
    (and
      extents
      (> (- (nth 2 extents) (nth 0 extents)) 1.0)
      (> (- (nth 3 extents) (nth 1 extents)) 1.0)
    )
    (progn
      (setq width (- (nth 2 extents) (nth 0 extents)))
      (setq height (- (nth 3 extents) (nth 1 extents)))
      (setq dx (- width (nth 1 spec)))
      (setq dy (- height (nth 2 spec)))
      (if (<= (sqrt (+ (* dx dx) (* dy dy))) 20.0)
        (list (nth 0 extents) (nth 1 extents) 0.0)
        nil
      )
    )
        nil
      )
    )
  )
)

(defun fra:find-companion-paper-insert
  (frame spec / selection index entity data name pattern frame-data
    frame-point frame-layout frame-sx frame-sy frame-rotation candidate found)
  ;; Some Tianzheng deliverables place a host-local yct-W-H paper block at
  ;; exactly the same anchor as the external A0/A1/A2 frame.  It is visually
  ;; part of the old frame but is not nested in the XREF, so deleting only the
  ;; XREF leaves a complete old border underneath the replacement.  Accept a
  ;; companion only when layout, exact paper-size name, anchor, scale and
  ;; rotation all agree, and only when the match is unique.
  (setq found nil)
  (setq candidate nil)
  (setq frame-data (entget frame))
  (setq frame-point (fra:get 10 frame-data))
  (setq frame-layout (strcase (fra:layout-name frame)))
  (setq frame-sx (fra:insert-scale-x frame-data))
  (setq frame-sy (fra:insert-scale-y frame-data))
  (setq frame-rotation (fra:insert-rotation frame-data))
  (setq pattern
    (strcat
      "*YCT-" (itoa (fix (+ (nth 1 spec) 0.5))) "-"
      (itoa (fix (+ (nth 2 spec) 0.5))) "-*"))
  (setq selection (ssget "_X" '((0 . "INSERT"))))
  (if selection
    (progn
      (setq index 0)
      (while (< index (sslength selection))
        (setq entity (ssname selection index))
        (if (not (equal entity frame))
          (progn
            (setq data (entget entity))
            (setq name (strcase (fra:s (fra:get 2 data))))
            (if
              (and
                (wcmatch name pattern)
                (= (strcase (fra:layout-name entity)) frame-layout)
                (< (distance (fra:get 10 data) frame-point) 1.0)
                (< (abs (- (fra:insert-scale-x data) frame-sx)) 0.000001)
                (< (abs (- (fra:insert-scale-y data) frame-sy)) 0.000001)
                (< (fra:angle-difference
                     (fra:insert-rotation data) frame-rotation) 0.000001))
              (if candidate
                (setq found 'AMBIGUOUS)
                (setq candidate entity)))))
        (setq index (1+ index)))))
  (if (= found 'AMBIGUOUS) nil candidate)
)

(defun fra:spec-geometry-score (frame spec / error)
  (setq error (fra:spec-geometry-error frame spec))
  (cond
    ((null error) 0)
    ((<= error 2.0) 120)
    ((<= error 20.0) 60)
    ((<= error 100.0) 10)
    (T -80)
  )
)

(defun fra:string-replace-all (text old new / position)
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

(defun fra:normalize-paper (value / text)
  (setq text (strcase (fra:s value)))
  (setq text (vl-string-translate "X" "*" text))
  (setq text (fra:string-replace-all text " " ""))
  text
)

(defun fra:title-paper-score (title spec / value normalized expected)
  (setq value (fra:aval "图幅" (fra:attr-pairs title)))
  (setq normalized (fra:normalize-paper value))
  (setq expected (fra:normalize-paper (fra:paper-label spec)))
  (cond
    ((= normalized "") 0)
    ((= normalized expected) 100)
    ((= normalized (strcase (car spec))) 80)
    (T -10)
  )
)

(defun fra:frame-score (frame title spec / fdata tdata score)
  (setq fdata (entget frame))
  (setq tdata (entget title))
  (setq score
    (+
      (fra:frame-control-score frame)
      (fra:frame-name-score frame)
      (fra:spec-geometry-score frame spec)
      (fra:title-paper-score title spec)
    )
  )
  (if
    (= (strcase (fra:s (fra:get 8 fdata)))
       (strcase (fra:s (fra:get 8 tdata))))
    (setq score (+ score 5))
  )
  score
)

(defun fra:equivalent-frame-results-p (left right / ldata rdata)
  ;; Several consultant drawings contain stacked copies of the same frame
  ;; and title at exactly the same transform.  Those instances are
  ;; interchangeable and must be consumed one-by-one, not rejected as a
  ;; geometric ambiguity.
  (setq ldata (entget (car left)))
  (setq rdata (entget (car right)))
  (and
    (= (strcase (fra:layout-name (car left)))
       (strcase (fra:layout-name (car right))))
    (= (strcase (fra:s (car (nth 2 left))))
       (strcase (fra:s (car (nth 2 right)))))
    (< (distance (fra:get 10 ldata) (fra:get 10 rdata)) 0.000001)
    (< (abs (- (fra:insert-scale-x ldata) (fra:insert-scale-x rdata)))
       0.000001)
    (< (abs (- (fra:insert-scale-y ldata) (fra:insert-scale-y rdata)))
       0.000001)
    (< (fra:angle-difference
         (fra:insert-rotation ldata)
         (fra:insert-rotation rdata))
       0.000001)
  )
)

(defun fra:best-frame-for-title
  (title candidates used / best second frame spec error score result)
  (setq best nil)
  (setq second nil)
  (foreach frame candidates
    (if (not (member frame used))
      (foreach spec (fra:frame-specs)
        (setq error (fra:spec-error frame title spec))
        (if (and (numberp error) (<= error 2.0))
          (progn
            (setq score (fra:frame-score frame title spec))
            (setq result (list frame title spec score error))
            (if
              (or
                (null best)
                (> score (nth 3 best))
                (and (= score (nth 3 best)) (< error (nth 4 best)))
              )
              (progn
                (setq second best)
                (setq best result)
              )
              (if
                (or
                  (null second)
                  (> score (nth 3 second))
                  (and (= score (nth 3 second)) (< error (nth 4 second)))
                )
                (setq second result)
              )
            )
          )
        )
      )
    )
  )
  (cond
    ((null best) nil)
    ((and second
          (not (fra:equivalent-frame-results-p best second))
          (= (nth 3 best) (nth 3 second))
          (< (abs (- (nth 4 best) (nth 4 second))) 0.5))
      (list "AMBIGUOUS" title best second)
    )
    (T best)
  )
)

(defun fra:pair-frames
  (candidates titles / pairs ambiguous used result title)
  (setq pairs '())
  (setq ambiguous '())
  (setq used '())
  ;; A replaced drawing can still contain old detail-title inserts at the
  ;; same paper-space anchor.  Pair the assistant's own NEW_TITLE block
  ;; first so a nearby detail title cannot claim the new border and make a
  ;; subsequent scan report the wrong DWG NAME / DWG NO.
  (setq titles
    (append
      (vl-remove-if-not
        '(lambda (item)
          (fra:assistant-title-p (fra:get 2 (entget item))))
        titles
      )
      (vl-remove-if
        '(lambda (item)
          (fra:assistant-title-p (fra:get 2 (entget item))))
        titles
      )
    )
  )
  (foreach title titles
    (setq result (fra:best-frame-for-title title candidates used))
    (cond
      ((null result) nil)
      ((= (car result) "AMBIGUOUS")
        (setq ambiguous (cons result ambiguous))
      )
      (T
        (setq pairs (cons result pairs))
        (setq used (cons (car result) used))
      )
    )
  )
  (list (reverse pairs) (reverse ambiguous))
)

(defun fra:world-from-local
  (frame local / data point sx sy rotation x y)
  (setq data (entget frame))
  (setq point (fra:get 10 data))
  (setq sx (fra:insert-scale-x data))
  (setq sy (fra:insert-scale-y data))
  (setq rotation (fra:insert-rotation data))
  (setq x (* sx (car local)))
  (setq y (* sy (cadr local)))
  (list
    (+ (car point)
       (- (* x (cos rotation)) (* y (sin rotation))))
    (+ (cadr point)
       (* x (sin rotation))
       (* y (cos rotation)))
    (if (numberp (caddr point)) (caddr point) 0.0)
  )
)

(defun fra:xref-name-spec (frame / name found spec)
  (setq name (strcase (fra:s (fra:get 2 (entget frame)))))
  (setq found nil)
  (foreach spec (fra:frame-specs)
    (if (= name (strcase (car spec))) (setq found spec))
  )
  found
)

(defun fra:likely-base-xref-p (frame / data name record path upper)
  (setq data (entget frame))
  (setq name (fra:s (fra:get 2 data)))
  (setq record (tblsearch "BLOCK" name))
  (setq path (if record (fra:s (fra:get 1 record)) ""))
  (setq upper (strcase (strcat name "|" path)))
  (or
    (wcmatch upper "*BASEPLAN*")
    (wcmatch upper "*底图*")
  )
)

(defun fra:xref-frame-spec (frame / best best-error spec error by-name)
  ;; Named paper-size XREFs are common and safe to accept immediately.  This
  ;; avoids traversing very large Baseplan block definitions merely to prove
  ;; that they are not an A0/A1/A2 border.
  (setq by-name (fra:xref-name-spec frame))
  (setq best nil)
  (setq best-error nil)
  (if
    (and (null by-name) (not (fra:likely-base-xref-p frame)))
    (foreach spec (fra:frame-specs)
      (setq error (fra:spec-geometry-error frame spec))
      (if
        (and
          (numberp error)
          (<= error 20.0)
          (or (null best-error) (< error best-error))
        )
        (progn
          (setq best spec)
          (setq best-error error)
        )
      )
    )
  )
  (if by-name by-name best)
)

(defun fra:contained-title-score
  (frame title spec / local x y max-y center-x)
  (setq local
    (if
      (= (strcase (fra:layout-name frame))
         (strcase (fra:layout-name title)))
      (fra:local-title-offset frame title)
      nil
    )
  )
  (if (null local)
    nil
    (progn
      (setq x (car local))
      (setq y (cadr local))
      (setq max-y (min 200.0 (* (nth 2 spec) 0.25)))
      (if
        (and
          (>= x 0.0)
          (<= x (nth 1 spec))
          (>= y 0.0)
          (<= y max-y)
        )
        (progn
          (setq center-x (/ (nth 1 spec) 2.0))
          (+ (abs (- y 10.0)) (* 0.05 (abs (- x center-x))))
        )
        nil
      )
    )
  )
)

(defun fra:best-contained-title
  (frame spec titles used / title score best best-score)
  (setq best nil)
  (setq best-score nil)
  (foreach title titles
    (if (not (member title used))
      (progn
        (setq score (fra:contained-title-score frame title spec))
        (if
          (and
            (numberp score)
            (or (null best-score) (< score best-score))
          )
          (progn
            (setq best title)
            (setq best-score score)
          )
        )
      )
    )
  )
  best
)

(defun fra:virtual-xref-pairs
  (candidates used titles used-titles / out frame spec title local-used)
  (setq out '())
  (setq local-used used-titles)
  (foreach frame candidates
    (if
      (and
        (not (member frame used))
        (fra:xref-p frame)
        (setq spec (fra:xref-frame-spec frame))
      )
      (progn
        (setq title
          (fra:best-contained-title frame spec titles local-used)
        )
        (if title (setq local-used (cons title local-used)))
        (setq out
          (cons (list frame title spec 0 0.0 "VIRTUAL") out)
        )
      )
    )
  )
  (reverse out)
)

(defun fra:line-endpoints (entity / data first second)
  (setq data (entget entity))
  (setq first (fra:get 10 data))
  (setq second (fra:get 11 data))
  (if (and first second) (list first second) nil)
)

(defun fra:point-near-p (left right tolerance)
  (and left right (< (distance left right) tolerance))
)

(defun fra:find-layout-line (lines layout first second / found entity data ends)
  (setq found nil)
  (foreach entity lines
    (if (null found)
      (progn
        (setq data (entget entity))
        (setq ends (fra:line-endpoints entity))
        (if
          (and
            ends
            (= (strcase (fra:s (fra:get 410 data))) (strcase layout))
            (or
              (and
                (fra:point-near-p (car ends) first 0.5)
                (fra:point-near-p (cadr ends) second 0.5))
              (and
                (fra:point-near-p (car ends) second 0.5)
                (fra:point-near-p (cadr ends) first 0.5))))
          (setq found entity)))))
  found
)

(defun fra:point-inside-paper-p (point origin spec tolerance)
  (and
    point
    (>= (car point) (- (car origin) tolerance))
    (<= (car point) (+ (car origin) (nth 1 spec) tolerance))
    (>= (cadr point) (- (cadr origin) tolerance))
    (<= (cadr point) (+ (cadr origin) (nth 2 spec) tolerance)))
)

(defun fra:loose-layout-text-candidates
  (texts layout origin spec / out entity data point relative-x relative-y)
  (setq out '())
  (foreach entity texts
    (setq data (entget entity))
    (setq point (fra:get 10 data))
    (if
      (and
        point
        (= (strcase (fra:s (fra:get 410 data))) (strcase layout))
        (fra:point-inside-paper-p point origin spec 1.0)
        (setq relative-x (- (car point) (car origin)))
        (setq relative-y (- (cadr point) (cadr origin)))
        (>= relative-x (- (nth 1 spec) 20.0))
        (<= relative-y 55.0))
      (setq out (cons entity out))))
  out
)

(defun fra:nearest-loose-layout-text
  (texts target-y excluded / best best-distance entity data point distance text)
  (setq best nil)
  (setq best-distance nil)
  (foreach entity texts
    (if (not (member entity excluded))
      (progn
        (setq data (entget entity))
        (setq point (fra:get 10 data))
        (setq text (fra:attribute-value data))
        (setq distance (abs (- (cadr point) target-y)))
        (if
          (and
            (/= text "")
            (or (null best-distance) (< distance best-distance)))
          (progn
            (setq best entity)
            (setq best-distance distance)))))
  )
  (if (and best best-distance (<= best-distance 7.0)) best nil)
)

(defun fra:loose-layout-cleanup-entities
  (layout origin spec lines texts hatches / out entity data ends point)
  (setq out '())
  ;; Paper-space drawing content is carried by VIEWPORT/INSERT/LWPOLYLINE in
  ;; these consultant sheets.  Only loose LINE geometry wholly inside the
  ;; proven ISO border belongs to the exploded frame/title grid.
  (foreach entity lines
    (setq data (entget entity))
    (setq ends (fra:line-endpoints entity))
    (if
      (and
        ends
        (= (strcase (fra:s (fra:get 410 data))) (strcase layout))
        (fra:point-inside-paper-p (car ends) origin spec 1.0)
        (fra:point-inside-paper-p (cadr ends) origin spec 1.0))
      (setq out (cons entity out))))
  ;; Remove only text in the right-hand title strip.  Drawing captions and
  ;; viewport labels elsewhere in the layout remain untouched.
  (foreach entity texts
    (setq data (entget entity))
    (setq point (fra:get 10 data))
    (if
      (and
        point
        (= (strcase (fra:s (fra:get 410 data))) (strcase layout))
        (fra:point-inside-paper-p point origin spec 1.0)
        (>= (car point) (+ (car origin) (- (nth 1 spec) 90.0))))
      (setq out (cons entity out))))
  ;; Title logos are commonly one paper-space solid hatch.  Restrict removal
  ;; to the known title-hatch layer so design hatches are never consumed.
  (foreach entity hatches
    (setq data (entget entity))
    (if
      (and
        (= (strcase (fra:s (fra:get 410 data))) (strcase layout))
        (wcmatch (strcase (fra:s (fra:get 8 data))) "*PUB_HATCH*"))
      (setq out (cons entity out))))
  (reverse out)
)

(defun fra:join-entity-handles (entities / output entity handle)
  (setq output "")
  (foreach entity entities
    (setq handle (fra:s (fra:get 5 (entget entity))))
    (if (/= handle "")
      (setq output
        (if (= output "") handle (strcat output "|" handle)))))
  output
)

(defun fra:loose-layout-pairs
  (/ line-selection text-selection hatch-selection lines texts hatches
    index entity data ends layout origin spec width height top left right
    candidates name-text number-text attrs cleanup pairs existing-origins)
  (setq lines '() texts '() hatches '() pairs '() existing-origins '())
  (setq line-selection (ssget "_X" '((0 . "LINE"))))
  (if line-selection
    (progn
      (setq index 0)
      (while (< index (sslength line-selection))
        (setq lines (cons (ssname line-selection index) lines))
        (setq index (1+ index)))))
  (setq text-selection (ssget "_X" '((0 . "TEXT,MTEXT"))))
  (if text-selection
    (progn
      (setq index 0)
      (while (< index (sslength text-selection))
        (setq texts (cons (ssname text-selection index) texts))
        (setq index (1+ index)))))
  (setq hatch-selection (ssget "_X" '((0 . "HATCH"))))
  (if hatch-selection
    (progn
      (setq index 0)
      (while (< index (sslength hatch-selection))
        (setq hatches (cons (ssname hatch-selection index) hatches))
        (setq index (1+ index)))))
  (foreach entity lines
    (setq data (entget entity))
    (setq layout (fra:s (fra:get 410 data)))
    (setq ends (fra:line-endpoints entity))
    (if
      (and
        ends
        (/= (strcase layout) "MODEL")
        (< (abs (- (cadr (car ends)) (cadr (cadr ends)))) 0.5))
      (foreach spec (fra:frame-specs)
        (setq width (nth 1 spec))
        (setq height (nth 2 spec))
        (if (< (abs (- (distance (car ends) (cadr ends)) width)) 0.5)
          (progn
            (setq origin
              (list
                (min (car (car ends)) (car (cadr ends)))
                (cadr (car ends))
                0.0))
            (if
              (not
                (vl-some
                  '(lambda (item)
                    (and
                      (= (strcase (car item)) (strcase layout))
                      (fra:point-near-p (cadr item) origin 0.5)))
                  existing-origins))
              (progn
                (setq top
                  (fra:find-layout-line lines layout
                    (list (car origin) (+ (cadr origin) height) 0.0)
                    (list (+ (car origin) width) (+ (cadr origin) height) 0.0)))
                (setq left
                  (fra:find-layout-line lines layout origin
                    (list (car origin) (+ (cadr origin) height) 0.0)))
                (setq right
                  (fra:find-layout-line lines layout
                    (list (+ (car origin) width) (cadr origin) 0.0)
                    (list (+ (car origin) width) (+ (cadr origin) height) 0.0)))
                (if (and top left right)
                  (progn
                    (setq candidates
                      (fra:loose-layout-text-candidates
                        texts layout origin spec))
                    (setq number-text
                      (fra:nearest-loose-layout-text
                        candidates (+ (cadr origin) 18.0) '()))
                    (setq name-text
                      (fra:nearest-loose-layout-text
                        candidates (+ (cadr origin) 30.0)
                        (if number-text (list number-text) '())))
                    (if (and name-text number-text)
                      (progn
                        (setq attrs
                          (list
                            (cons "图名"
                              (fra:visible-loose-text (entget name-text)))
                            (cons "图号"
                              (fra:visible-loose-text (entget number-text)))
                            (cons "图幅" (fra:paper-label spec))))
                        (setq cleanup
                          (fra:loose-layout-cleanup-entities
                            layout origin spec lines texts hatches))
                        (setq pairs
                          (cons
                            (list entity name-text spec 1000 0.0
                              "LOOSE_LAYOUT" attrs cleanup origin)
                            pairs))
                        (setq existing-origins
                          (cons (list layout origin) existing-origins)))))))))))))
  (reverse pairs)
)

(defun fra:remove-item (item items / out x)
  (setq out '())
  (foreach x items
    (if (not (equal x item)) (setq out (cons x out)))
  )
  (reverse out)
)

(defun fra:pair-point (pair)
  (if (= (strcase (fra:s (nth 5 pair))) "LOOSE_LAYOUT")
    (nth 8 pair)
    (fra:get 10 (entget (car pair))))
)

(defun fra:string-lessp (left right / index limit lc rc result decided)
  ;; Keep this independent of Visual LISP comparison helpers: neither
  ;; VL-STRING-LESSP nor LAYOUTLIST is available in every Core Console build.
  (setq index 1)
  (setq limit (min (strlen left) (strlen right)))
  (setq result nil)
  (setq decided nil)
  (while (and (not decided) (<= index limit))
    (setq lc (ascii (substr left index 1)))
    (setq rc (ascii (substr right index 1)))
    (cond
      ((< lc rc)
        (setq result T)
        (setq decided T)
      )
      ((> lc rc)
        (setq result nil)
        (setq decided T)
      )
      (T
        (setq index (1+ index))
      )
    )
  )
  (if decided result (< (strlen left) (strlen right)))
)

(defun fra:sort-pairs-spatial
  (pairs / item point min-x max-x min-y max-y horizontal)
  (setq min-x nil)
  (setq max-x nil)
  (setq min-y nil)
  (setq max-y nil)
  (foreach item pairs
    (setq point (fra:pair-point item))
    (if point
      (progn
        (setq min-x (if min-x (min min-x (car point)) (car point)))
        (setq max-x (if max-x (max max-x (car point)) (car point)))
        (setq min-y (if min-y (min min-y (cadr point)) (cadr point)))
        (setq max-y (if max-y (max max-y (cadr point)) (cadr point)))
      )
    )
  )
  (setq horizontal
    (or
      (null min-x)
      (>= (- max-x min-x) (- max-y min-y))
    )
  )
  (vl-sort
    pairs
    (function
      (lambda (left right / lp rp ll rl)
        (setq lp (fra:pair-point left))
        (setq rp (fra:pair-point right))
        (setq ll (strcase (fra:layout-name (car left))))
        (setq rl (strcase (fra:layout-name (car right))))
        (cond
          ((fra:string-lessp ll rl) T)
          ((fra:string-lessp rl ll) nil)
          (horizontal
            (if (< (abs (- (car lp) (car rp))) 0.000001)
              (> (cadr lp) (cadr rp))
              (< (car lp) (car rp))
            )
          )
          (T
            (if (< (abs (- (cadr lp) (cadr rp))) 0.000001)
              (< (car lp) (car rp))
              (> (cadr lp) (cadr rp))
            )
          )
        )
      )
    )
  )
)

(defun fra:leading-digits (text / output index code)
  (setq output "")
  (setq index 1)
  (while (<= index (strlen text))
    (setq code (ascii (substr text index 1)))
    (if (and (>= code 48) (<= code 57))
      (progn
        (setq output (strcat output (substr text index 1)))
        (setq index (1+ index))
      )
      (setq index (1+ (strlen text)))
    )
  )
  output
)

(defun fra:trailing-digits (text / output index code)
  (setq output "")
  (setq index (strlen text))
  (while (> index 0)
    (setq code (ascii (substr text index 1)))
    (if (and (>= code 48) (<= code 57))
      (progn
        (setq output (strcat (substr text index 1) output))
        (setq index (1- index))
      )
      (setq index 0)
    )
  )
  output
)

(defun fra:cross-group-decimal-range-p
  (stem / wave left right left-dot right-dot left-group right-group)
  (setq wave (vl-string-search "~" stem))
  (if wave
    (progn
      (setq left (substr stem 1 wave))
      (setq right (substr stem (+ wave 2)))
      (setq left-dot (fra:last-substring-position "." left))
      (setq right-dot (vl-string-search "." right))
      (if (and left-dot right-dot)
        (progn
          (setq left-group
            (fra:trailing-digits (substr left 1 left-dot))
          )
          (setq right-group (fra:leading-digits right))
          (and
            (/= left-group "")
            (/= right-group "")
            (/= (atoi left-group) (atoi right-group))
          )
        )
        nil
      )
    )
    nil
  )
)

(defun fra:zero-pad-number (value width / text)
  (setq text (itoa value))
  (while (< (strlen text) width)
    (setq text (strcat "0" text))
  )
  text
)

(defun fra:range-number-info
  (stem / wave left right left-digits right-digits prefix)
  (setq wave (vl-string-search "~" stem))
  (if wave
    (progn
      (setq left (substr stem 1 wave))
      (setq right (substr stem (+ wave 2)))
      (setq left-digits (fra:trailing-digits left))
      (setq right-digits (fra:leading-digits right))
      (if
        (and
          (/= left-digits "")
          (/= right-digits "")
          (<= (atoi left-digits) (atoi right-digits))
        )
        (progn
          (setq prefix
            (substr left 1 (- (strlen left) (strlen left-digits)))
          )
          (list
            prefix
            (atoi left-digits)
            (strlen left-digits)
            (atoi right-digits)
          )
        )
        nil
      )
    )
    nil
  )
)

(defun fra:multi-sheet-number-info
  (drawing pair-count / stem dot suffix digits range-info)
  (if (<= pair-count 1)
    nil
    (progn
      (setq drawing (fra:source-drawing-name drawing))
      (setq stem (vl-filename-base drawing))
      (setq stem (fra:string-replace-all stem "～" "~"))
      (setq range-info (fra:range-number-info stem))
      (if
        (and
          range-info
          (<= (+ (cadr range-info) (1- pair-count))
              (nth 3 range-info))
        )
        range-info
        (progn
          (setq dot (vl-string-search "." stem))
          (if (and dot (not (fra:cross-group-decimal-range-p stem)))
            (progn
              (setq suffix (substr stem (+ dot 2)))
              (setq digits (fra:leading-digits suffix))
              (if
                (and
                  (/= digits "")
                  (vl-string-search "-" (substr stem 1 dot))
                )
                (list
                  (strcat (substr stem 1 dot) ".")
                  (atoi digits)
                  0
                  nil
                )
                nil
              )
            )
            nil
          )
        )
      )
    )
  )
)

(defun fra:sequence-drawing-number (sequence-info pair-index / value width)
  (setq value (+ (cadr sequence-info) (1- pair-index)))
  (setq width (nth 2 sequence-info))
  (strcat
    (car sequence-info)
    (if (and (numberp width) (> width 0))
      (fra:zero-pad-number value width)
      (itoa value)
    )
  )
)

(defun fra:format-paper-dimension (value / rounded)
  (setq rounded (fix (+ value 0.0000001)))
  (if (< (abs (- value rounded)) 0.000001)
    (itoa rounded)
    (rtos value 2 2)
  )
)

(defun fra:paper-label (spec)
  (strcat
    (fra:format-paper-dimension (nth 1 spec))
    "*"
    (fra:format-paper-dimension (nth 2 spec))
  )
)

(defun fra:asset-path (directory spec / separator)
  (setq separator
    (if (or (= directory "") (wcmatch directory "*[/\\]"))
      ""
      "\\"
    )
  )
  (strcat directory separator (nth 3 spec) ".dwg")
)

(defun fra:angle-difference (a b / two-pi d)
  (setq two-pi (* 2.0 pi))
  (setq d (abs (- a b)))
  (while (>= d two-pi) (setq d (- d two-pi)))
  (if (> d pi) (- two-pi d) d)
)

(defun fra:assistant-title-p (name / upper prefix)
  (setq upper (strcase (fra:s name)))
  (setq prefix "NEW_TITLE_CFR_")
  (or
    (= upper "NEW_TITLE")
    (and
      (= (substr upper 1 (strlen prefix)) prefix)
      (fra:all-digits-p (substr upper (1+ (strlen prefix))))
    )
  )
)

(defun fra:private-title-import-directory (/ configured attempt path made)
  (setq configured (fra:env "FRAME_TITLE_IMPORT_DIRECTORY" ""))
  (cond
    ((/= configured "")
      (if (vl-file-directory-p configured) configured nil))
    ((and fra:title-import-directory
          (vl-file-directory-p fra:title-import-directory))
      fra:title-import-directory)
    (T
      ;; Standalone APPLOAD/testing also uses a private directory. Directory
      ;; creation claims the name; a competing session must choose another.
      (setq attempt 0 made nil)
      (while (and (< attempt 10) (not made))
        (setq path (vl-filename-mktemp "CFRIM" (getvar "TEMPPREFIX") ".dir"))
        (setq made (vl-mkdir path) attempt (1+ attempt)))
      (if made (setq fra:title-import-directory path) nil))))

(defun fra:fresh-title-source (library / cached index name path copied key directory)
  ;; Cache only definitions imported during THIS processing run.  Existing
  ;; NEW_TITLE definitions may contain obsolete label/attribute positions.
  (setq key (strcase library))
  (setq cached (cdr (assoc key fra:title-import-cache)))
  (if (and cached (tblobjname "BLOCK" cached))
    (list cached cached nil key)
    (progn
      (setq directory (fra:private-title-import-directory))
      (if (not directory)
        (setq fra:last-frame-insert-error "Cannot create private title import directory"))
      (setq index 1)
      (setq path nil)
      (while (and directory (not path))
        (setq name (strcat "NEW_TITLE_CFR_" (itoa index)))
        (setq copied (strcat directory "/" name ".dwg"))
        (if (and (not (tblobjname "BLOCK" name)) (not (findfile copied)))
          (setq path copied)
          (setq index (1+ index))
        )
      )
      ;; A unique DWG filename imports a unique block definition without
      ;; redefining any existing references in the user's drawing.
      (setq copied (if path (vl-catch-all-apply 'vl-file-copy (list library path))))
      (if (and (not (vl-catch-all-error-p copied)) copied)
        (list path name path key)
        (progn
          (if path
            (setq fra:last-frame-insert-error
              (strcat "Title template copy failed: " library " -> " path
                (if (vl-catch-all-error-p copied)
                  (strcat "; " (vl-catch-all-error-message copied)) ""))))
          nil)
      )
    )
  )
)

(defun fra:insert (library local-name point sx sy rotation / fresh result)
  (setq fra:last-frame-insert-error "")
  (if (and (= (strcase local-name) "NEW_TITLE") (/= (fra:s library) ""))
    (progn
      (setq fresh (fra:fresh-title-source library))
      (if fresh
        (progn
          (setq result
            (vl-catch-all-apply 'fra:insert-source
              (list (car fresh) (cadr fresh) point sx sy rotation (cadr fresh)))
          )
          (if (caddr fresh) (vl-file-delete (caddr fresh)))
          (if (vl-catch-all-error-p result)
            (progn
              (setq fra:last-frame-insert-error
                (strcat "Title import failed: " (vl-catch-all-error-message result)))
              (princ (strcat "\nTitle import failed: " (vl-catch-all-error-message result)))
              nil
            )
            (progn
              (if result
                (setq fra:title-import-cache
                  (cons (cons (cadddr fresh) (cadr fresh)) fra:title-import-cache))
              )
              result
            )
          )
        )
        (progn (princ "\nCannot copy current title template for import.") nil)
      )
    )
    (fra:insert-source library local-name point sx sy rotation nil)
  )
)

(defun fra:insert-source
  (library local-name point sx sy rotation
    expected-name
    / source before after data rotation-degrees valid
      command-point ucs-xdir ucs-angle command-rotation)
  (setq source
    (if (tblobjname "BLOCK" local-name) local-name library)
  )
  (setq before (entlast))
  (setq command-point (trans point 0 1))
  (setq ucs-xdir (getvar "UCSXDIR"))
  (setq ucs-angle
    (angle '(0.0 0.0 0.0) (list (car ucs-xdir) (cadr ucs-xdir) 0.0))
  )
  (setq command-rotation (- rotation ucs-angle))
  (setq rotation-degrees (* command-rotation (/ 180.0 pi)))
  (command
    "_.-INSERT"
    source
    "_non"
    command-point
    sx
    sy
    (rtos rotation-degrees 2 12)
  )
  (setq after (entlast))
  (setq valid nil)
  (if (and after (not (equal after before)) (= (fra:get 0 (entget after)) "INSERT"))
    (progn
      (setq data (entget after))
      (setq valid
        (and
          (or (not expected-name)
              (= (strcase (fra:s (fra:get 2 data))) (strcase expected-name)))
          (< (distance point (fra:get 10 data)) 0.000001)
          (< (abs (- sx (fra:get 41 data))) 0.000001)
          (< (abs (- sy (fra:get 42 data))) 0.000001)
          (< (fra:angle-difference rotation (fra:get 50 data)) 0.000001)
        )
      )
    )
  )
  (if valid
    after
    (progn
      (setq fra:last-frame-insert-error
        (strcat "Inserted block failed transform/name validation: " local-name
          "; source=" source "; expected_point=" (fra:p point)
          "; actual_dxf=" (vl-princ-to-string data)))
      (if (and after (not (equal after before))) (entdel after))
      nil
    )
  )
)

(defun fra:set-attribute-text (data value / out item embedded)
  ;; Multiline ATTRIB entities store the displayed text in an embedded
  ;; MTEXT payload introduced by DXF group 101 "Embedded Object".
  ;; Keep the ordinary group 1 value and the embedded MTEXT group 1 value
  ;; synchronized.  Updating only the first group 1 makes the Properties
  ;; palette look correct while the visible title-block text stays blank.
  (setq out '())
  (setq embedded nil)
  (foreach item data
    (cond
      ((and (= (car item) 101) (= (cdr item) "Embedded Object"))
        (setq embedded T)
        (setq out (cons item out))
      )
      ((= (car item) 1)
        (setq out
          (cons
            (cons 1 (if embedded (strcat "\\W0.8000;" value) value))
            out
          )
        )
      )
      ((and embedded (= (car item) 3)) nil)
      (T
        (setq out (cons item out))
      )
    )
  )
  (reverse out)
)

(defun fra:set-attribute-invisible (data invisible / flags updated)
  (setq flags (fra:get 70 data))
  (if (not (numberp flags)) (setq flags 0))
  (setq updated
    (if invisible
      (logior flags 1)
      (if (/= 0 (logand flags 1)) (- flags 1) flags)))
  (if (assoc 70 data)
    (subst (cons 70 updated) (assoc 70 data) data)
    (append data (list (cons 70 updated))))
)

(defun fra:fit-drawing-number-attribute (data value / length target current)
  ;; Long drawing numbers must fit the fixed-width DWG NO. cell.  Leaving
  ;; the template width factor unchanged makes characters overprint one
  ;; another and look like two stacked drawing numbers.
  (setq length (strlen (fra:s value)))
  (if (> length 10)
    (progn
      (setq target (max 0.40 (/ 7.5 length)))
      (setq current (fra:get 41 data))
      (if (not (numberp current)) (setq current 0.8))
      (setq target (min current target))
      (if (assoc 41 data)
        (setq data (subst (cons 41 target) (assoc 41 data) data))
        (setq data (append data (list (cons 41 target))))
      )
    )
  )
  data
)

(defun fra:fit-overlay-attribute
  (data value maximum-width maximum-height minimum-height scale-x scale-y
    / units height width-factor required factor embedded out item)
  ;; Cell limits are in template units, but inserted ATTRIB and embedded
  ;; MTEXT heights are already in drawing units. Preserve the INSERT scale
  ;; instead of replacing a 50x attribute height with an unscaled number.
  (setq scale-x (abs scale-x))
  (setq scale-y (abs scale-y))
  (setq maximum-width (* maximum-width scale-x))
  (setq maximum-height (* maximum-height scale-y))
  (setq minimum-height (* minimum-height scale-y))
  ;; strlen is deliberately conservative in AutoCAD 2020 MBCS (a Chinese
  ;; glyph counts as two bytes).  The result can be slightly smaller than
  ;; necessary, but it will not cross the title-cell border.
  (setq units (max 1 (strlen (fra:s value))))
  ;; Some Tianzheng/SHX renderers ignore a very narrow ATTRIB width factor.
  ;; Fit by reducing text height first so the visible glyphs stay inside the
  ;; cell even when group 41 is rendered as the style default.  Width-factor
  ;; compression is reserved for values that still do not fit at min height.
  ;; Width factor is relative to height; preserve nonuniform X/Y scaling.
  (setq width-factor (* 0.8 (/ scale-x scale-y)))
  (setq height
    (min maximum-height
      (/ maximum-width (* units width-factor))))
  (if (< height minimum-height) (setq height minimum-height))
  ;; Exceptionally long values need both minimum height and width compression.
  (setq required (* units height width-factor))
  (if (> required maximum-width)
    (setq width-factor (/ maximum-width (* units height)))
  )
  (if (assoc 40 data)
    (setq data (subst (cons 40 height) (assoc 40 data) data))
    (setq data (append data (list (cons 40 height))))
  )
  (if (assoc 41 data)
    (setq data (subst (cons 41 width-factor) (assoc 41 data) data))
    (setq data (append data (list (cons 41 width-factor))))
  )
  ;; A multiline attribute contains a second MTEXT payload.  Its height and
  ;; inline width override must match the outer ATTRIB, otherwise Properties
  ;; reports the fitted size while AutoCAD/Tianzheng still draws the old size.
  (setq embedded nil)
  (setq out '())
  (foreach item data
    (cond
      ((and (= (car item) 101) (= (cdr item) "Embedded Object"))
        (setq embedded T)
        (setq out (cons item out)))
      ((and embedded (= (car item) 40))
        (setq out (cons (cons 40 height) out)))
      ((and embedded (= (car item) 1))
        (setq out
          (cons
            (cons 1
              (strcat "\\W" (rtos width-factor 2 4) ";" (fra:s value)))
            out)))
      (T (setq out (cons item out)))
    )
  )
  (setq data (reverse out))
  data
)

(defun fra:original-title-geometry (values title / attrs tag entry data)
  ;; Capture per-instance data, never a filename, scale bucket or ATTDEF.
  ;; ATTRIB text coordinates/heights already include the original transform.
  (if title
    (progn
      (setq attrs (fra:attribute-entities title))
      (foreach tag '("图名" "图号")
        (setq entry (assoc tag attrs))
        (if entry
          (progn
            (setq data (entget (cdr entry)))
            (if (and (assoc 10 data) (assoc 40 data)
                     (> (cdr (assoc 40 data)) 0.0))
              (setq values (cons (cons (strcat "__CFR_GEOMETRY_" tag) data) values))))))))
  (cons (cons "__CFR_REQUIRE_TEXT_GEOMETRY" "1") values)
)

(defun fra:original-title-transform (data fallback-point frame-sx frame-sy frame-rotation)
  ;; Read the original per-instance INSERT values without rounding or using
  ;; the frame's scale for a native title. Missing native DXF values follow
  ;; INSERT defaults; virtual/loose titles retain their existing fallback.
  (if data
    (list
      (if (assoc 10 data) (fra:get 10 data) fallback-point)
      (if (numberp (fra:get 41 data)) (fra:get 41 data) 1.0)
      (if (numberp (fra:get 42 data)) (fra:get 42 data) 1.0)
      (if (numberp (fra:get 50 data)) (fra:get 50 data) 0.0))
    (list fallback-point frame-sx frame-sy frame-rotation))
)

(defun fra:attribute-text-body (data / active out item)
  ;; Skip source identity, owner, reactors and extension-dictionary handles.
  ;; Keep the complete text/attribute body, including repeated DXF groups
  ;; and the embedded MTEXT payload. A group-by-group assoc copy loses these.
  (setq active nil out '())
  (foreach item data
    (if (and (= (car item) 100) (= (cdr item) "AcDbText"))
      (setq active T))
    (if active (setq out (cons item out))))
  (reverse out)
)

(defun fra:preserved-title-data (destination source value / prefix body item active)
  (setq body (fra:attribute-text-body source))
  (setq prefix '() active T)
  (foreach item destination
    (if (and (= (car item) 100) (= (cdr item) "AcDbText"))
      (setq active nil))
    (if active (setq prefix (cons item prefix))))
  (if body
    (progn
      ;; If the visible text is unchanged, preserve its raw contents too:
      ;; \P, inline height/width/font overrides and fields must survive.
      (if (/= value (fra:attribute-value source))
        (setq body (fra:set-preserved-attribute-text body value)))
      (append (reverse prefix) body))
    nil)
)

(defun fra:mtext-leading-format (text / index length char finish out opens)
  ;; For an explicitly edited name/number, retain leading format commands.
  ;; Unedited rich text uses the exact original payload above.
  (setq index 1 length (strlen text) out "" opens 0)
  (while (<= index length)
    (setq char (substr text index 1))
    (cond
      ((= char "{")
        (setq out (strcat out char) opens (1+ opens) index (1+ index)))
      ((and (= char "\\") (< index length)
            (member (strcase (substr text (1+ index) 1))
              '("H" "W" "F" "C" "T" "Q" "A")))
        (setq finish (vl-string-search ";" text (1- index)))
        (if finish
          (setq out (strcat out (substr text index (+ 2 (- finish index))))
                index (+ finish 2))
          (setq index (1+ length))))
      (T (setq index (1+ length)))))
  (list out opens)
)

(defun fra:set-preserved-attribute-text (data value / out embedded item old-content format suffix index)
  (setq old-content "" embedded nil)
  (foreach item data
    (if (= (car item) 101) (setq embedded T))
    (if (and embedded (member (car item) '(1 3)))
      (setq old-content (strcat old-content (cdr item)))))
  (setq format (fra:mtext-leading-format old-content) suffix "" index (cadr format))
  (repeat index (setq suffix (strcat suffix "}")))
  (setq out '() embedded nil)
  (foreach item data
    (cond
      ((and (= (car item) 101) (= (cdr item) "Embedded Object"))
        (setq embedded T out (cons item out)))
      ((= (car item) 1)
        (setq out (cons (cons 1 (if embedded (strcat (car format) value suffix) value)) out)))
      ((and embedded (= (car item) 3)) nil)
      (T (setq out (cons item out)))))
  (reverse out)
)

(defun fra:set-attributes
  (insert values / next data pair tag overlay-p new-title-p visibility
    insert-data scale-x scale-y original geometry-data)
  (setq insert-data (entget insert))
  (setq scale-x (fra:insert-scale-x insert-data))
  (setq scale-y (fra:insert-scale-y insert-data))
  (setq overlay-p
    (= (strcase (fra:s (fra:get 2 (entget insert))))
       "CFR_XREF_TITLE_OVERLAY")
  )
  (setq new-title-p
    (fra:assistant-title-p (fra:get 2 (entget insert)))
  )
  (setq next (entnext insert))
  (while next
    (setq data (entget next))
    (cond
      ((= (fra:get 0 data) "ATTRIB")
        (setq tag (fra:s (fra:get 2 data)))
        (setq pair (assoc tag values))
        (if pair
          (progn
            (setq original (assoc (strcat "__CFR_GEOMETRY_" tag) values))
            (if (and (member tag '("图名" "图号")) (not original)
                     (= (fra:aval "__CFR_REQUIRE_TEXT_GEOMETRY" values) "1"))
              (progn
                (princ (strcat "\nCFR-E109 Missing original attribute geometry: " tag
                  "; source drawing must be kept; no template geometry fallback"))
                (exit)))
            (if original
              (progn
                (setq geometry-data (fra:preserved-title-data data (cdr original) (cdr pair)))
                (if geometry-data (setq data geometry-data)
                  (progn
                    (princ (strcat "\nCFR-E109 Original text geometry cannot be preserved: " tag))
                    (exit))))
              (setq data (fra:set-attribute-text data (cdr pair))))
            (if (fra:personnel-name-tag-p tag)
              (progn
                (setq visibility
                  (fra:aval (strcat "__CFR_VISIBLE_" tag) values))
                (if (/= visibility "")
                  (setq data
                    (fra:set-attribute-invisible
                      data (/= visibility "1")))
                )
              )
            )
            (if (and (not original) (= tag "图号"))
              (setq data
                (if (or overlay-p new-title-p)
                  (fra:fit-overlay-attribute
                    data (cdr pair) 18.0 2.4 1.2 scale-x scale-y)
                  (fra:fit-drawing-number-attribute data (cdr pair))
                )
              )
            )
            (if (and (not original) (or overlay-p new-title-p) (= tag "图名"))
              (setq data
                (fra:fit-overlay-attribute
                  data (cdr pair) 66.0
                  (if overlay-p 3.0 4.0)
                  1.2 scale-x scale-y)
              )
            )
            (if (not (entmod data))
              (progn
                (princ (strcat "\nCFR-E109 Attribute write failed: " tag))
                (exit)))
            (entupd next)
          )
        )
      )
      ((= (fra:get 0 data) "SEQEND")
        (setq next nil)
      )
    )
    (if next (setq next (entnext next)))
  )
  (entupd insert)
)

(defun fra:attribute-entities (insert / next data out)
  (setq out '())
  (setq next (entnext insert))
  (while next
    (setq data (entget next))
    (cond
      ((= (fra:get 0 data) "ATTRIB")
        (setq out
          (cons
            (cons (fra:s (fra:get 2 data)) next)
            out
          )
        )
      )
      ((= (fra:get 0 data) "SEQEND")
        (setq next nil)
      )
    )
    (if next (setq next (entnext next)))
  )
  out
)

(defun fra:clean-cloned-entity-data (data / output pair layer-found)
  (setq output '())
  (setq layer-found nil)
  (foreach pair data
    (cond
      ((member (car pair) '(-1 5 330 360 67 410)) nil)
      ((= (car pair) 102) nil)
      ((= (car pair) 8)
        ;; XREF-dependent layers such as A2|0 must not leak into the
        ;; embedded signature block.
        (setq output (cons '(8 . "0") output))
        (setq layer-found T)
      )
      (T
        (setq output (cons pair output))
      )
    )
  )
  (if (not layer-found)
    (setq output (cons '(8 . "0") output))
  )
  (reverse output)
)

(defun fra:clone-dependent-block
  (source-name / cached record record-data target-name base result
    source entity data etype ok copied)
  (setq cached (assoc source-name fra:preserved-block-cache))
  (if cached
    (cdr cached)
    (progn
      (setq record (tblobjname "BLOCK" source-name))
      (if (null record)
        nil
        (progn
          (setq record-data (entget record))
          (setq target-name
            (strcat "CFRKEEP_" (fra:s (fra:get 5 record-data)))
          )
          (if (tblobjname "BLOCK" target-name)
            (setq result target-name)
            (progn
              (setq base (fra:get 10 (tblsearch "BLOCK" source-name)))
              (setq result
                (entmake
                  (list
                    '(0 . "BLOCK")
                    '(100 . "AcDbEntity")
                    '(8 . "0")
                    '(100 . "AcDbBlockBegin")
                    (cons 2 target-name)
                    '(70 . 0)
                    (cons 10 base)
                    (cons 3 target-name)
                    '(1 . "")
                  )
                )
              )
              (setq ok (if result T nil))
              (setq copied 0)
              (setq source (entnext record))
              (while source
                (setq data (entget source))
                (setq etype (fra:s (fra:get 0 data)))
                (if (= etype "ENDBLK")
                  (setq source nil)
                  (progn
                    ;; An associative hatch (group 71 = 1) points back to
                    ;; XREF-owned boundary entities.  Calling ENTMAKE on it
                    ;; leaves the block builder in an invalid state, whereas
                    ;; its visible LWPOLYLINE boundaries are self-contained.
                    (if
                      (not
                        (and
                          (= etype "HATCH")
                          (= (fra:get 71 data) 1)
                        )
                      )
                      (if
                        (entmake
                          (fra:clean-cloned-entity-data data)
                        )
                        (setq copied (1+ copied))
                      )
                    )
                    (setq source (entnext source))
                  )
                )
              )
              (if
                (null
                  (entmake
                    '(
                      (0 . "ENDBLK")
                      (100 . "AcDbEntity")
                      (8 . "0")
                      (100 . "AcDbBlockEnd")
                    )
                  )
                )
                (setq ok nil)
              )
              ;; Associative HATCH objects inside some signature blocks keep
              ;; XREF-only reactors and cannot be recreated independently.
              ;; Preserve every entity that AutoCAD accepts (normally the
              ;; complete visible LWPOLYLINE signature); one rejected hatch
              ;; must not erase the rest of the signature.
              (setq result
                (if (and ok (> copied 0)) target-name nil)
              )
            )
          )
          (if result
            (setq fra:preserved-block-cache
              (cons
                (cons source-name result)
                fra:preserved-block-cache
              )
            )
          )
          result
        )
      )
    )
  )
)

(defun fra:entity-point-extents
  (data / extents pair code point x y)
  (setq extents nil)
  (foreach pair data
    (setq code (car pair))
    (setq point (cdr pair))
    (if
      (and
        (member code '(10 11 12 13 14 15 16 17 18))
        (listp point)
        (numberp (car point))
        (numberp (cadr point))
      )
      (progn
        (setq x (car point))
        (setq y (cadr point))
        (setq extents
          (if extents
            (list
              (min (nth 0 extents) x)
              (min (nth 1 extents) y)
              (max (nth 2 extents) x)
              (max (nth 3 extents) y)
            )
            (list x y x y)
          )
        )
      )
    )
  )
  extents
)

(defun fra:direct-signature-items
  (block spec / output width entity data etype extents)
  (setq output '())
  (setq width (nth 1 spec))
  (setq entity (if block (entnext block) nil))
  (while entity
    (setq data (entget entity))
    (setq etype (fra:s (fra:get 0 data)))
    (cond
      ((= etype "ENDBLK")
        (setq entity nil)
      )
      ;; Some old title blocks contain exploded handwritten signatures:
      ;; hundreds of short LINEs and outlined LWPOLYLINEs rather than INSERTs.
      ;; Only accept geometry wholly inside the right signature column, so
      ;; frame/title borders are never copied.
      ((member etype '("LINE" "LWPOLYLINE" "SPLINE" "ARC" "CIRCLE" "ELLIPSE"))
        (setq extents (fra:entity-point-extents data))
        (if
          (and
            extents
            (>= (nth 0 extents) (- width 45.0))
            (<= (nth 2 extents) (- width 5.0))
            (>= (nth 1 extents) 30.0)
            (<= (nth 3 extents) 118.0)
          )
          (setq output
            (cons
              (list entity (nth 1 extents) (nth 3 extents))
              output
            )
          )
        )
      )
    )
    (if entity (setq entity (entnext entity)))
  )
  (vl-sort output
    '(lambda (left right) (< (cadr left) (cadr right)))
  )
)

(defun fra:direct-signature-clusters
  (items / clusters current current-min current-max item item-min item-max)
  (setq clusters '())
  (setq current '())
  (setq current-min nil)
  (setq current-max nil)
  (foreach item items
    (setq item-min (cadr item))
    (setq item-max (caddr item))
    (if
      (or
        (null current)
        (<= item-min (+ current-max 1.0))
      )
      (progn
        (setq current (cons (car item) current))
        (if (null current-min) (setq current-min item-min))
        (setq current-max
          (if current-max (max current-max item-max) item-max)
        )
      )
      (progn
        (setq clusters
          (cons
            (list (reverse current) current-min current-max)
            clusters
          )
        )
        (setq current (list (car item)))
        (setq current-min item-min)
        (setq current-max item-max)
      )
    )
  )
  (if current
    (setq clusters
      (cons
        (list (reverse current) current-min current-max)
        clusters
      )
    )
  )
  (reverse clusters)
)

(defun fra:direct-signature-candidates
  (block spec / output cluster center row)
  (setq output '())
  (foreach cluster
    (fra:direct-signature-clusters
      (fra:direct-signature-items block spec)
    )
    (setq center (/ (+ (cadr cluster) (caddr cluster)) 2.0))
    (setq row
      (fra:nearest-row-spec
        (- center 10.0)
        (fra:signature-row-specs)
      )
    )
    (if row
      (setq output
        (cons
          (list (car row) "DIRECT" (car cluster) center)
          output
        )
      )
    )
  )
  (reverse output)
)

(defun fra:clone-direct-signature-block
  (frame entities center
    / frame-data source-record source-data target-name result ok copied
      entity data etype)
  (setq frame-data (entget frame))
  (setq source-record
    (tblobjname "BLOCK" (fra:s (fra:get 2 frame-data)))
  )
  (setq source-data (if source-record (entget source-record) nil))
  (setq target-name
    (strcat
      "CFRKEEPD_"
      (fra:s (fra:get 5 source-data))
      "_"
      (itoa (fix (+ 0.5 (* center 10.0))))
    )
  )
  (if (tblobjname "BLOCK" target-name)
    target-name
    (progn
      (setq result
        (entmake
          (list
            '(0 . "BLOCK")
            '(100 . "AcDbEntity")
            '(8 . "0")
            '(100 . "AcDbBlockBegin")
            (cons 2 target-name)
            '(70 . 0)
            '(10 0.0 0.0 0.0)
            (cons 3 target-name)
            '(1 . "")
          )
        )
      )
      (setq ok (if result T nil))
      (setq copied 0)
      (foreach entity entities
        (setq data (entget entity))
        (setq etype (fra:s (fra:get 0 data)))
        (if
          (and
            (member etype
              '("LINE" "LWPOLYLINE" "SPLINE" "ARC" "CIRCLE" "ELLIPSE"))
            (entmake (fra:clean-cloned-entity-data data))
          )
          (setq copied (1+ copied))
        )
      )
      (if
        (null
          (entmake
            '(
              (0 . "ENDBLK")
              (100 . "AcDbEntity")
              (8 . "0")
              (100 . "AcDbBlockEnd")
            )
          )
        )
        (setq ok nil)
      )
      (if (and ok (> copied 0)) target-name nil)
    )
  )
)

(defun fra:xref-signature-candidates
  (frame spec / output frame-data block block-name cache-key cached
    entity data etype point width x y row source-name)
  (setq frame-data (entget frame))
  (setq block-name (fra:s (fra:get 2 frame-data)))
  (setq block
    (tblobjname "BLOCK" block-name)
  )
  (setq cache-key
    (strcat (strcase block-name) "|" (strcase (car spec)))
  )
  (setq cached (assoc cache-key fra:xref-signature-cache))
  (if cached
    (cadr cached)
    (progn
      (setq output '())
      (setq width (nth 1 spec))
      (setq entity (if block (entnext block) nil))
      (while entity
        (setq data (entget entity))
        (setq etype (fra:s (fra:get 0 data)))
        (cond
          ((= etype "ENDBLK")
            (setq entity nil)
          )
          ((= etype "INSERT")
            (setq point (fra:get 10 data))
            (if (and point (numberp (car point)) (numberp (cadr point)))
              (progn
                (setq x (car point))
                (setq y (cadr point))
                (setq row
                  (if
                    (and
                      (>= x (- width 45.0))
                      (<= x (- width 5.0))
                      (>= y 34.0)
                      (<= y 114.0)
                    )
                    (fra:nearest-row-spec
                      (- y 10.0)
                      (fra:signature-row-specs)
                    )
                    nil
                  )
                )
                (setq source-name (fra:s (fra:get 2 data)))
                (if (and row (tblobjname "BLOCK" source-name))
                  (setq output
                    (cons
                      (list (car row) "BLOCK" entity)
                      output
                    )
                  )
                )
              )
            )
          )
        )
        (if entity (setq entity (entnext entity)))
      )
      (setq output
        (append (reverse output)
          (fra:direct-signature-candidates block spec)
        )
      )
      (setq fra:xref-signature-cache
        (cons (list cache-key output) fra:xref-signature-cache)
      )
      output
    )
  )
)

(defun fra:make-local-insert
  (name point sx sy rotation layer-name / before made reference data)
  ;; The external-DWG -INSERT command applies unit conversion and can reject
  ;; deep-cloned XREF-dependent blocks even after their definition is local.
  ;; Build the ordinary block reference directly in the current layout.
  (setq before (entlast))
  (setq made
    (entmake
      (list
        '(0 . "INSERT")
        '(100 . "AcDbEntity")
        (cons 8 (if (= layer-name "") "0" layer-name))
        '(100 . "AcDbBlockReference")
        (cons 2 name)
        (cons 10 point)
        (cons 41 sx)
        (cons 42 sy)
        '(43 . 1.0)
        (cons 50 rotation)
        '(210 0.0 0.0 1.0)
      )
    )
  )
  (setq reference (if made (entlast) nil))
  (if
    (and
      reference
      (not (equal reference before))
      (= (fra:s (fra:get 0 (entget reference))) "INSERT")
      (= (strcase (fra:s (fra:get 2 (entget reference))))
         (strcase name))
    )
    reference
    nil
  )
)

(defun fra:preserve-xref-signatures
  (frame spec values layer-name
    / ok references candidate column kind nested nested-data local-name
      target sx sy rotation reference frame-data entities center)
  (setq ok T)
  (setq references '())
  (setq frame-data (entget frame))
  (foreach candidate (fra:xref-signature-candidates frame spec)
    (setq column (car candidate))
    (setq kind (cadr candidate))
    ;; Blank means preserve.  A supplied DWG replaces the original and the
    ;; clear sentinel explicitly removes it.
    (if (= (fra:aval column values) "")
      (progn
        (if (= kind "DIRECT")
          (progn
            (setq entities (caddr candidate))
            (setq center (cadddr candidate))
            (setq local-name
              (fra:clone-direct-signature-block
                frame entities center
              )
            )
            (setq target (fra:get 10 frame-data))
            (setq sx (fra:insert-scale-x frame-data))
            (setq sy (fra:insert-scale-y frame-data))
            (setq rotation (fra:insert-rotation frame-data))
          )
          (progn
            (setq nested (caddr candidate))
            (setq nested-data (entget nested))
            (setq local-name
              (fra:clone-dependent-block
                (fra:s (fra:get 2 nested-data))
              )
            )
            (setq target
              (fra:world-from-local frame (fra:get 10 nested-data))
            )
            (setq sx
              (* (fra:insert-scale-x frame-data)
                 (fra:insert-scale-x nested-data))
            )
            (setq sy
              (* (fra:insert-scale-y frame-data)
                 (fra:insert-scale-y nested-data))
            )
            (setq rotation
              (+ (fra:insert-rotation frame-data)
                 (fra:insert-rotation nested-data))
            )
          )
        )
        (setq reference
          (if local-name
            (fra:make-local-insert
              local-name target sx sy rotation layer-name)
            nil
          )
        )
        (if reference
          (progn
            (setq references (cons reference references))
          )
          (progn
            (setq ok nil)
            (setq fra:last-signature-error
              (strcat
                "Original XREF signature preserve failed: "
                (if (= kind "DIRECT")
                  column
                  (fra:s (fra:get 2 (entget nested)))
                )
              )
            )
          )
        )
      )
    )
  )
  (list ok (reverse references))
)

(defun fra:preserved-signature-count
  (frame spec values / count candidate)
  (setq count 0)
  (foreach candidate (fra:xref-signature-candidates frame spec)
    (if (= (fra:aval (car candidate) values) "")
      (setq count (1+ count))
    )
  )
  count
)

(defun fra:find-new-insert-after
  (before name target sx sy rotation / entity data found target-layout)
  (setq found nil)
  (setq target-layout (strcase (getvar "CTAB")))
  (setq entity (if before (entnext before) (entnext)))
  (while entity
    (setq data (entget entity))
    (if
      (and
        (= (fra:get 0 data) "INSERT")
        (= (strcase (fra:s (fra:get 2 data))) (strcase name))
        (= (strcase (fra:s (fra:get 410 data))) target-layout)
        (< (distance target (fra:get 10 data)) 0.000001)
        (< (abs (- sx (fra:get 41 data))) 0.000001)
        (< (abs (- sy (fra:get 42 data))) 0.000001)
        (< (fra:angle-difference rotation (fra:get 50 data)) 0.000001)
      )
      (setq found entity)
    )
    (setq entity (entnext entity))
  )
  found
)

(defun fra:insert-signature
  (library target sx sy rotation layer-name
    / local-name source command-point ucs-xdir ucs-angle
      command-rotation rotation-degrees before reference data)
  (setq fra:last-signature-error "")
  (setq local-name (vl-filename-base library))
  (setq source
    (if (tblobjname "BLOCK" local-name) local-name library)
  )
  (setq command-point (trans target 0 1))
  (setq ucs-xdir (getvar "UCSXDIR"))
  (setq ucs-angle
    (angle '(0.0 0.0 0.0) (list (car ucs-xdir) (cadr ucs-xdir) 0.0))
  )
  (setq command-rotation (- rotation ucs-angle))
  (setq rotation-degrees (* command-rotation (/ 180.0 pi)))
  (setq before (entlast))
  (command
    "_.-INSERT"
    source
    "_non"
    command-point
    sx
    sy
    (rtos rotation-degrees 2 12)
  )
  ;; Importing a DWG may add nested block entities after the model reference,
  ;; so inspect only entities created by this insertion instead of scanning
  ;; every INSERT in model space.
  (setq reference
    (fra:find-new-insert-after before local-name target sx sy rotation)
  )
  (if reference
    (progn
      (if (and layer-name (/= layer-name ""))
        (progn
          (setq data (entget reference))
          (setq data
            (subst (cons 8 layer-name) (assoc 8 data) data)
          )
          (entmod data)
          (entupd reference)
        )
      )
      reference
    )
    (progn
      (setq fra:last-signature-error
        (strcat "Signature DWG insert failed: " library))
      nil
    )
  )
)

(defun fra:insert-signatures
  (title values sx sy rotation
    / ok references anchors spec path anchor target reference layer-name)
  (setq ok T)
  (setq references '())
  (setq layer-name (fra:s (fra:get 8 (entget title))))
  (setq anchors (fra:attribute-entities title))
  (foreach spec (fra:signature-specs)
    (setq path (fra:aval (car spec) values))
    (if
      (and
        (/= path "")
        (/= path "__CFR_CLEAR_SIGNATURE__")
      )
      (progn
        (setq anchor (cdr (assoc (cdr spec) anchors)))
        (setq target (if anchor (fra:get 10 (entget anchor)) nil))
        (setq reference
          (if target
            (fra:insert-signature path target sx sy rotation layer-name)
            (progn
              (setq fra:last-signature-error
                (strcat "Signature anchor not found: " (cdr spec)))
              nil
            )
          )
        )
        (if reference
          (setq references (cons reference references))
          (setq ok nil)
        )
      )
    )
  )
  (list ok (reverse references))
)

(defun fra:ensure-overlay-layer (/ name)
  (setq name "CFR-XREF-TITLE-OVERLAY")
  (if (null (tblsearch "LAYER" name))
    (entmake
      (list '(0 . "LAYER") '(100 . "AcDbSymbolTableRecord")
        '(100 . "AcDbLayerTableRecord") (cons 2 name)
        '(70 . 0) '(62 . 7) '(6 . "Continuous"))
    )
  )
  name
)

(defun fra:overlay-mask-content (width height / count text)
  ;; MTEXT background fill follows actual glyph extents.  One non-breaking
  ;; space made only a tiny patch, so the old proxy text remained visible.
  (setq count (max 1 (fix (/ width (max 0.5 (* height 0.55))))))
  (setq text "")
  (repeat count (setq text (strcat text "\\~")))
  text)

(defun fra:make-overlay-mask (point width height)
  (entmake
    (list '(0 . "MTEXT") '(100 . "AcDbEntity") '(8 . "0")
      '(100 . "AcDbMText") (cons 10 point) (cons 40 height)
      (cons 41 width) '(71 . 5)
      (cons 1 (fra:overlay-mask-content width height)) '(7 . "Standard")
      '(90 . 17) '(45 . 1.0) '(210 0.0 0.0 1.0))
  )
)

(defun fra:make-overlay-attdef
  (tag point height width-factor invisible / flags)
  (setq flags (if invisible 1 0))
  (entmake
    (list '(0 . "ATTDEF") '(8 . "0") (cons 10 point)
      (cons 11 point) (cons 40 height) '(1 . "")
      (cons 3 tag) (cons 2 tag) (cons 70 flags)
      '(72 . 1) '(74 . 2) (cons 41 width-factor)
      '(50 . 0.0) '(7 . "Standard"))
  )
)

(defun fra:ensure-xref-overlay-block (values / name project-name project-number)
  (setq project-name (fra:aval "设计项目名" values))
  (setq project-number (fra:aval "设计项目号" values))
  (setq name
    (cond
      ((and (/= project-name "") (/= project-number ""))
        "CFR_XREF_TITLE_OVERLAY_GEOM2_BOTH")
      ((/= project-name "") "CFR_XREF_TITLE_OVERLAY_GEOM2_PROJECT_NAME")
      ((/= project-number "") "CFR_XREF_TITLE_OVERLAY_GEOM2_PROJECT_NO")
      (T "CFR_XREF_TITLE_OVERLAY")))
  (if (null (tblobjname "BLOCK" name))
    (progn
      (entmake
        (list '(0 . "BLOCK") '(100 . "AcDbEntity") '(8 . "0")
          '(100 . "AcDbBlockBegin") (cons 2 name) '(70 . 2)
          '(10 0.0 0.0 0.0) (cons 3 name) '(1 . ""))
      )
      ;; Fixed masks are inset from the standard 70 mm title grid.
      (fra:make-overlay-mask '(-35.0 120.0 0.0) 66.0 10.0)
      (fra:make-overlay-mask '(-10.0 12.0 0.0) 18.0 5.0)
      (fra:make-overlay-attdef "图名" '(-35.0 120.0 0.0) 3.0 0.8 nil)
      (fra:make-overlay-attdef "图号" '(-10.0 12.0 0.0) 2.4 0.8 nil)
      ;; Only create a global-field mask when the user supplied that field.
      ;; Blank top inputs therefore continue to preserve the original XREF.
      (if (/= project-number "")
        (progn
          ;; In the consultant A2 title, y=30 is the Approved row.  Project
          ;; No. is the next grid row below it, centred at y=22.
          (fra:make-overlay-attdef
            "设计项目号" '(-35.0 22.0 0.0) 3.0 0.8 nil)))
      (if (/= project-name "")
        (progn
          ;; y=140 is the Subitem row in this frame family.  Project Name is
          ;; one 20 mm grid row above it.
          (fra:make-overlay-attdef
            "设计项目名" '(-35.0 160.0 0.0) 4.0 0.8 nil)))
      (fra:make-overlay-attdef "图幅" '(0.0 0.0 0.0) 1.0 1.0 T)
      (fra:make-overlay-attdef
        "CFR_FRAME_HANDLE" '(0.0 0.0 0.0) 1.0 1.0 T)
      (entmake
        '((0 . "ENDBLK") (100 . "AcDbEntity") (8 . "0")
          (100 . "AcDbBlockEnd")))
    )
  )
  name
)

(defun fra:clear-old-overlay-wipeouts (/ selection index)
  (if (not fra:overlay-wipeouts-cleared)
    (progn
      (setq selection
        (ssget "_X" '((0 . "WIPEOUT") (8 . "CFR-XREF-TITLE-OVERLAY"))))
      (if selection
        (progn
          (setq index 0)
          (while (< index (sslength selection))
            (entdel (ssname selection index))
            (setq index (1+ index)))))
      (setq fra:overlay-wipeouts-cleared T)))
)

(defun fra:make-xref-field-wipeout
  (frame center width height / half-width half-height p1 p2 p3 p4 before mask data)
  (fra:clear-old-overlay-wipeouts)
  (setq half-width (/ width 2.0))
  (setq half-height (/ height 2.0))
  (setq p1
    (fra:world-from-local frame
      (list (- (car center) half-width) (- (cadr center) half-height))))
  (setq p2
    (fra:world-from-local frame
      (list (+ (car center) half-width) (- (cadr center) half-height))))
  (setq p3
    (fra:world-from-local frame
      (list (+ (car center) half-width) (+ (cadr center) half-height))))
  (setq p4
    (fra:world-from-local frame
      (list (- (car center) half-width) (+ (cadr center) half-height))))
  (setq before (entlast))
  (vl-cmdf "_.WIPEOUT" p1 p2 p3 p4 "_Close")
  (setq mask (entlast))
  (if (and mask (/= mask before) (= (fra:s (fra:get 0 (entget mask))) "WIPEOUT"))
    (progn
      (setq data (entget mask))
      (setq data (subst (cons 8 (fra:ensure-overlay-layer)) (assoc 8 data) data))
      (entmod data)
      (entupd mask)
      (vl-cmdf "_.DRAWORDER" mask "" "_Front")
      mask)
    nil)
)

(defun fra:make-xref-global-wipeouts (frame spec values / width ok mask)
  (setq width (nth 1 spec))
  (setq ok T)
  (if (/= (fra:aval "设计项目号" values) "")
    (progn
      (setq mask
        (fra:make-xref-field-wipeout
          frame (list (- width 45.0) 32.0) 66.0 7.0))
      (if (null mask) (setq ok nil))))
  (if (/= (fra:aval "设计项目名" values) "")
    (progn
      (setq mask
        (fra:make-xref-field-wipeout
          frame (list (- width 45.0) 170.0) 66.0 12.0))
      (if (null mask) (setq ok nil))))
  ok
)

(defun fra:find-xref-overlay
  (frame-handle / selection index entity attrs found)
  (setq found nil)
  (setq selection
    (ssget "_X" '((0 . "INSERT") (2 . "CFR_XREF_TITLE_OVERLAY*")))
  )
  (if selection
    (progn
      (setq index 0)
      (while (< index (sslength selection))
        (setq entity (ssname selection index))
        (setq attrs (fra:attr-pairs entity))
        (if (= (strcase (fra:aval "CFR_FRAME_HANDLE" attrs))
               (strcase frame-handle))
          (if found (entdel entity) (setq found entity))
        )
        (setq index (1+ index))
      )
    )
  )
  found
)

(defun fra:upsert-xref-title-overlay
  (frame title-point sx sy rotation values
    / frame-handle overlay name data layer existing-ok)
  (setq frame-handle (fra:s (fra:get 5 (entget frame))))
  (setq name (fra:ensure-xref-overlay-block values))
  (setq layer (fra:ensure-overlay-layer))
  (setq overlay (fra:find-xref-overlay frame-handle))
  (setq existing-ok nil)
  (if overlay
    (progn
      (setq data (entget overlay))
      (setq existing-ok
        (and (= (strcase (fra:s (fra:get 2 data))) (strcase name))
          (= (strcase (fra:layout-name overlay))
                 (strcase (fra:layout-name frame)))
          (< (distance title-point (fra:get 10 data)) 0.000001)
          (< (abs (- sx (fra:insert-scale-x data))) 0.000001)
          (< (abs (- sy (fra:insert-scale-y data))) 0.000001)
          (< (fra:angle-difference rotation (fra:insert-rotation data))
             0.000001)))
      (if (not existing-ok)
        (progn (entdel overlay) (setq overlay nil)))
    )
  )
  (if (null overlay)
    (setq overlay (fra:insert "" name title-point sx sy rotation))
  )
  (if overlay
    (progn
      (setq data (entget overlay))
      (setq data (subst (cons 8 layer) (assoc 8 data) data))
      (entmod data)
      (entupd overlay)
      (setq values
        (fra:put-value values "CFR_FRAME_HANDLE" frame-handle))
      (fra:set-attributes overlay (fra:original-title-geometry values nil))
      overlay)
    nil)
)

(defun fra:delete-entities (entities / item)
  (foreach item entities
    (if item (entdel item))
  )
)

(defun fra:write-log (f values / out value)
  (setq out "")
  (foreach value values
    (setq out
      (if (= out "")
        (fra:s value)
        (strcat out "\t" (fra:s value))
      )
    )
  )
  (write-line out f)
)

(defun fra:delete-proxy-title-handles (values / tag handle entity data kind)
  ;; These handles are recovered from the source graphics stream and identify
  ;; only the separately inserted old DWG NAME / DWG NO. objects.  Tianzheng
  ;; drawings may store them as proxy entities or as loose text/attribute
  ;; definitions in paper space.
  ;; Delete them after the replacement/overlay has succeeded so the new text
  ;; cannot overlap the old Tianzheng proxy text.
  (foreach tag
    '("__proxy_drawing_name_handle" "__proxy_drawing_number_handle")
    (setq handle (fra:aval tag values))
    (setq entity (if (/= handle "") (handent handle) nil))
    (if entity
      (progn
        (setq data (entget entity))
        (setq kind (fra:s (fra:get 0 data)))
        (if (member kind
              '("ACAD_PROXY_ENTITY" "TEXT" "MTEXT" "ATTRIB" "ATTDEF"))
          (entdel entity)
        )
      )
    )
  )
)

(defun c:REPLACEFRAMES
  (/ operation asset-directory title-library title-name log-path log-file
    dry-run collected candidates titles pairing pairs ambiguous pair
    used-frames used-titles virtual-pairs virtual-p loose-layout-pairs
    loose-layout-p title-only-titles loose-layout-attrs loose-layout-cleanup
    excluded-titles ambiguous-title title-only-count companion-paper
    frame title spec border-library border-name fdata tdata xrefattrs oldattrs values
    point title-point sx sy rotation title-sx title-sy title-rotation title-transform
    new-frame new-title replaced skipped
    project-owner project-name project-date project-number
    old-osmode old-aunits old-angbase old-angdir old-insunits editable-tags
    sheet-values-path sheet-values base-log-row signature-result
    signatures-ok inserted-signatures preserved-result preserved-ok
    preserved-signatures new-title-layer collect-start collect-ms
    replace-start replace-ms save-start save-ms old-ctab item best second
    sequence-info pair-index preserved-signature-count overlay masks-ok
    virtual-origin missing-required)
  (setq operation (strcase (fra:env "FRAME_OPERATION_MODE" "REPLACE")))
  (setq fra:proxy-title-needed nil)
  (setq fra:overlay-wipeouts-cleared nil)
  (if (not (member operation '("REPLACE" "UPDATE_TITLE")))
    (setq operation "REPLACE")
  )
  (setq asset-directory (fra:env "FRAME_ASSET_DIRECTORY" ""))
  (setq title-library (fra:env "FRAME_TITLE_LIBRARY" ""))
  (setq title-name (fra:env "FRAME_TITLE_BLOCK_NAME" "NEW_TITLE"))
  (setq log-path (fra:env "FRAME_REPLACE_LOG" "frame_replace.tsv"))
  (setq dry-run (= (fra:env "FRAME_DRY_RUN" "1") "1"))
  (setq project-owner
    (fra:env "FRAME_FIELD_OWNER" "")
  )
  (setq project-name
    (fra:env "FRAME_FIELD_PROJECT_NAME" "")
  )
  (setq project-date (fra:env "FRAME_FIELD_DATE" ""))
  (setq project-number (fra:env "FRAME_FIELD_PROJECT_NUMBER" ""))
  (setq editable-tags (fra:editable-tags))
  (setq sheet-values-path (fra:env "FRAME_SHEET_VALUES" ""))
  (setq sheet-values (fra:load-sheet-values sheet-values-path))

  (setq log-file (open log-path "w" "utf8"))
  (fra:write-log log-file
    (append
      (list
        "status" "drawing" "old_frame_handle" "old_frame_block"
        "old_title_handle" "point" "scale" "old_drawing_name"
        "old_drawing_number" "message" "layout" "title_point"
        "y_scale" "rotation" "frame_spec" "virtual_title"
        "preserved_signature_count" "companion_paper_handle"
      )
      editable-tags
    )
  )
  (setq replaced 0)
  (setq skipped 0)
  (setq collect-ms 0)
  (setq replace-ms 0)
  (setq save-ms 0)
  (setq title-only-count 0)

  (cond
    ((and (= operation "REPLACE") (not dry-run)
          (or (= asset-directory "") (not (vl-file-directory-p asset-directory))))
      (fra:write-log log-file
        (list "ERROR" (getvar "DWGNAME") "" "" "" "" "" "" ""
          "Frame asset directory not found")
      )
    )
    ((and (= operation "REPLACE") (not dry-run)
          (or (= title-library "") (null (findfile title-library))))
      (fra:write-log log-file
        (list "ERROR" (getvar "DWGNAME") "" "" "" "" "" "" ""
          "Title library not found")
      )
    )
    (T
      (setvar "CMDECHO" 0)
      (setvar "FILEDIA" 0)
      (setvar "ATTDIA" 0)
      (setvar "ATTREQ" 0)
      (setq old-osmode (getvar "OSMODE"))
      (setq old-aunits (getvar "AUNITS"))
      (setq old-angbase (getvar "ANGBASE"))
      (setq old-angdir (getvar "ANGDIR"))
      (setq old-insunits (getvar "INSUNITS"))
      (setq old-ctab (getvar "CTAB"))
      (setvar "OSMODE" 0)
      (setvar "AUNITS" 0)
      (setvar "ANGBASE" 0.0)
      (setvar "ANGDIR" 0)
      ;; Frame assets are deliberately geometry-driven.  Some source DWGs
      ;; incorrectly declare inches even though their frame definitions are
      ;; authored in millimetres.  External DWG insertion would then apply an
      ;; automatic 1/25.4 scale (for example 100 becomes 3.93701).  Neutralize
      ;; insertion units while importing assets, then restore the source value
      ;; before saving so the original drawing setting is preserved.
      (setvar "INSUNITS" 0)
      (setq fra:block-extents-cache '())
      (setq fra:title-import-cache '())
      (setq fra:title-import-directory nil)
      (setq fra:last-frame-insert-error "")
      (setq fra:preserved-block-cache '())
      (setq fra:xref-signature-cache '())
      (setq collect-start (getvar "MILLISECS"))
      (setq collected (fra:collect))
      (setq candidates (car collected))
      (setq titles (cadr collected))
      (setq pairing (fra:pair-frames candidates titles))
      (setq pairs (car pairing))
      (setq ambiguous (cadr pairing))
      (setq used-frames '())
      (setq used-titles '())
      (foreach pair pairs
        (setq used-frames (cons (car pair) used-frames))
        (if (cadr pair)
          (setq used-titles (cons (cadr pair) used-titles))
        )
      )
      (setq virtual-pairs
        (fra:virtual-xref-pairs
          candidates used-frames titles used-titles)
      )
      (setq loose-layout-pairs (fra:loose-layout-pairs))
      ;; Both modes use the same recognition result.  Replace mode swaps the
      ;; frame; UpdateTitle keeps the XREF and writes a host-local overlay for
      ;; drawing name/number only.
      (setq pairs (append pairs virtual-pairs loose-layout-pairs))
      (setq pairs (fra:sort-pairs-spatial pairs))
      ;; Title-only recovery is only safe when this drawing has no credible
      ;; paper frame at all.  If real/virtual frame pairs exist, the remaining
      ;; local blocks are usually detail captions inside the sheet (section
      ;; titles, detail numbers, etc.), not additional sheet title blocks.
      ;; Treating those captions as TITLE_ONLY rows duplicates sheet work and
      ;; can overwrite drawing content.  Keep the fallback for exploded-border
      ;; drawings, but disable it in mixed drawings and whenever frame matching
      ;; is ambiguous.
      (setq excluded-titles '())
      (foreach pair pairs
        (if (cadr pair)
          (setq excluded-titles (cons (cadr pair) excluded-titles))
        )
      )
      (foreach item ambiguous
        (setq ambiguous-title (cadr item))
        (if ambiguous-title
          (setq excluded-titles (cons ambiguous-title excluded-titles))
        )
      )
      (setq title-only-titles
        (if (and (= (length pairs) 0) (= (length ambiguous) 0))
          (vl-remove-if
            '(lambda (item) (member item excluded-titles))
            titles
          )
          '()
        )
      )
      (setq title-only-count (length title-only-titles))
      (setq sequence-info
        (fra:multi-sheet-number-info
          (getvar "DWGNAME")
          (+ (length pairs) title-only-count)
        )
      )
      (setq pair-index 0)
      (setq collect-ms
        (fra:ms-diff (getvar "MILLISECS") collect-start)
      )
      (setq replace-start (getvar "MILLISECS"))
      (foreach item ambiguous
        (setq title (cadr item))
        (setq best (caddr item))
        (setq second (cadddr item))
        (setq skipped (1+ skipped))
        (fra:write-log log-file
          (list
            "ERROR" (getvar "DWGNAME")
            (fra:get 5 (entget (car best)))
            (fra:get 2 (entget (car best)))
            (fra:get 5 (entget title))
            (fra:p (fra:get 10 (entget (car best))))
            (fra:n (fra:insert-scale-x (entget (car best))))
            (fra:aval "图名" (fra:attr-pairs title))
            (fra:aval "图号" (fra:attr-pairs title))
            (strcat
              "Ambiguous frame candidates: "
              (fra:s (fra:get 2 (entget (car best)))) "["
              (fra:s (fra:get 5 (entget (car best)))) "] and "
              (fra:s (fra:get 2 (entget (car second)))) "["
              (fra:s (fra:get 5 (entget (car second)))) "]")
          )
        )
      )
      (foreach title title-only-titles
        (setq pair-index (1+ pair-index))
        (setq tdata (entget title))
        (setq oldattrs (fra:attr-pairs title))
        (setq title-point (fra:get 10 tdata))
        (setq title-sx
          (if (numberp (fra:get 41 tdata)) (fra:get 41 tdata) 1.0))
        (setq title-sy
          (if (numberp (fra:get 42 tdata)) (fra:get 42 tdata) 1.0))
        (setq title-rotation
          (if (numberp (fra:get 50 tdata)) (fra:get 50 tdata) 0.0))
        ;; Deliberately use UPDATE_TITLE semantics even when the public mode
        ;; is unified Replace: the border was not reliably identified, so
        ;; paper size and geometry must remain untouched.
        (setq values
          (fra:initial-values
            oldattrs nil "UPDATE_TITLE" project-owner project-name
            project-date project-number
          )
        )
        (setq values
          (fra:apply-overrides
            values sheet-values (getvar "DWGNAME") (fra:get 5 tdata)
          )
        )
        (setq values (fra:clear-signature-attributes values))
        (setq missing-required
          (or
            (= (fra:aval "图名" values) "")
            (= (fra:aval "图号" values) "")
          )
        )
        (setq base-log-row
          (list
            "" (getvar "DWGNAME") (fra:get 5 tdata) "TITLE_ONLY"
            (fra:get 5 tdata) (fra:p title-point) (fra:n title-sx)
            (fra:aval "图名" oldattrs) (fra:aval "图号" oldattrs)
            "TITLE_ONLY; local editable title updated; border preserved"
            (fra:layout-name title) (fra:p title-point)
            (fra:n title-sy) (fra:n title-rotation)
            "TITLE_ONLY" "0" "0" ""
          )
        )
        (if (and (not dry-run) missing-required)
          (progn
            (setq skipped (1+ skipped))
            (fra:write-log log-file
              (list "ERROR" (getvar "DWGNAME")
                (fra:get 5 tdata) "TITLE_ONLY" (fra:get 5 tdata)
                (fra:p title-point) (fra:n title-sx)
                (fra:aval "图名" oldattrs)
                (fra:aval "图号" oldattrs)
                (strcat
                  "CFR-E106 Required title field missing: "
                  (if (= (fra:aval "图名" values) "") "图名 " "")
                  (if (= (fra:aval "图号" values) "") "图号" "")
                  "; source title kept")))
          )
          (if dry-run
          (progn
            (setq replaced (1+ replaced))
            (setq base-log-row (cons "PLANNED" (cdr base-log-row)))
            (fra:write-log log-file
              (append base-log-row
                (fra:values-for-tags editable-tags values)))
          )
          (progn
            (if (/= (strcase (getvar "CTAB"))
                    (strcase (fra:layout-name title)))
              (setvar "CTAB" (fra:layout-name title))
            )
            (setq signature-result
              (fra:insert-signatures
                title values title-sx title-sy title-rotation))
            (setq signatures-ok (car signature-result))
            (setq inserted-signatures (cadr signature-result))
            (if signatures-ok
              (progn
                (fra:set-attributes title (fra:original-title-geometry values title))
                (setq replaced (1+ replaced))
                (setq base-log-row (cons "UPDATED" (cdr base-log-row)))
                (fra:write-log log-file
                  (append base-log-row
                    (fra:values-for-tags editable-tags values)))
              )
              (progn
                (fra:delete-entities inserted-signatures)
                (setq skipped (1+ skipped))
                (fra:write-log log-file
                  (list "ERROR" (getvar "DWGNAME")
                    (fra:get 5 tdata) "TITLE_ONLY" (fra:get 5 tdata)
                    (fra:p title-point) (fra:n title-sx)
                    (fra:aval "图名" oldattrs)
                    (fra:aval "图号" oldattrs)
                    (strcat "Title-only update failed; border kept; "
                      fra:last-signature-error)))
              )
            )
          )
          )
        )
      )
      (foreach pair pairs
        (setq pair-index (1+ pair-index))
        (setq frame (nth 0 pair))
        (setq title (nth 1 pair))
        (setq spec (nth 2 pair))
        (setq virtual-p
          (= (strcase (fra:s (nth 5 pair))) "VIRTUAL")
        )
        (setq loose-layout-p
          (= (strcase (fra:s (nth 5 pair))) "LOOSE_LAYOUT")
        )
        (setq loose-layout-attrs
          (if loose-layout-p (nth 6 pair) '()))
        (setq loose-layout-cleanup
          (if loose-layout-p (nth 7 pair) '()))
        (setq virtual-origin
          (if virtual-p (fra:xref-frame-local-origin frame spec) nil)
        )
        (setq border-name (nth 3 spec))
        (setq border-library (fra:asset-path asset-directory spec))
        (setq fdata (entget frame))
        (if
          (and
            (= operation "REPLACE")
            (not dry-run)
            (null (findfile border-library))
          )
          (progn
            (setq skipped (1+ skipped))
            (fra:write-log log-file
              (list "SKIPPED" (getvar "DWGNAME") (fra:get 5 fdata)
                (fra:get 2 fdata) "" (fra:p (fra:get 10 fdata))
                (fra:n (fra:get 41 fdata)) "" ""
                (strcat "Frame asset not found: " border-library))
            )
          )
          (progn
            (setq tdata (if title (entget title) nil))
            (setq xrefattrs
              (if virtual-p
                (fra:xref-title-attrs frame spec)
                '()
              )
            )
            (setq oldattrs
              (if loose-layout-p
                loose-layout-attrs
                (if virtual-p
                (fra:overlay-fill-empty-attrs
                  xrefattrs
                  (if title (fra:attr-pairs title) '())
                )
                (if title (fra:attr-pairs title) '())
                )
              )
            )
            ;; Some local paper-space title blocks keep DWG NAME / DWG NO.
            ;; attributes blank and display the real values as nearby loose
            ;; TEXT/MTEXT/ATTDEF (often created by Tianzheng/exploded blocks).
            ;; Request the same read-only DXF recovery used for XREF proxy
            ;; titles whenever either required value is missing.
            (if
              (or
                virtual-p
                (= (fra:aval "鍥惧悕" oldattrs) "")
                (= (fra:aval "鍥惧彿" oldattrs) "")
              )
              (setq fra:proxy-title-needed T)
            )
            (setq point
              (if loose-layout-p
                (nth 8 pair)
                (if (and virtual-p virtual-origin)
                (fra:world-from-local frame virtual-origin)
                (fra:get 10 fdata)
                )
              )
            )
            (setq title-point
              (if loose-layout-p
                (list
                  (+ (car point) (- (nth 1 spec) 10.0))
                  (+ (cadr point) 10.0)
                  0.0)
                (if (and title (not virtual-p))
                (fra:get 10 tdata)
                (fra:world-from-local
                  frame
                  (list
                    (+ (if virtual-origin (car virtual-origin) 0.0)
                       (- (nth 1 spec) 10.0))
                    (+ (if virtual-origin (cadr virtual-origin) 0.0) 10.0)
                  )
                )
                )
              )
            )
            (setq sx (if (numberp (fra:get 41 fdata)) (fra:get 41 fdata) 1.0))
            (setq sy (if (numberp (fra:get 42 fdata)) (fra:get 42 fdata) 1.0))
            (setq rotation
              (if (numberp (fra:get 50 fdata)) (fra:get 50 fdata) 0.0)
            )
            ;; Initialize for every pair so title-only/previous sheet values
            ;; cannot leak into this replacement. Keep frame parameters apart.
            (setq title-transform
              (fra:original-title-transform
                (if (and title (not virtual-p) (not loose-layout-p)) tdata nil)
                title-point sx sy rotation))
            (setq title-point (car title-transform)
                  title-sx (cadr title-transform)
                  title-sy (caddr title-transform)
                  title-rotation (cadddr title-transform))
            (setq values
              (fra:initial-values
                oldattrs spec operation project-owner project-name
                project-date project-number
              )
            )
            ;; Never present filename-derived text as a value read from the
            ;; title block.  Shared A0/A1/A2 XREF files often contain blank
            ;; main-title attributes; in that case the GUI must show a blank
            ;; field for review instead of inventing a per-sheet number/name.
            (setq values
              (fra:apply-overrides
                values
                sheet-values
                (getvar "DWGNAME")
                (fra:get 5 fdata)
              )
            )
            ;; Blank personnel/signature fields mean preserve.  Only a
            ;; supplied replacement signature clears its right-hand text
            ;; anchor; the explicit clear sentinel removes both.
            (setq values (fra:clear-signature-attributes values))
            (setq missing-required
              (or
                (= (fra:aval "图名" values) "")
                (= (fra:aval "图号" values) "")
              )
            )
            (setq preserved-signature-count
              (if virtual-p
                (fra:preserved-signature-count frame spec values)
                0
              )
            )
            (setq companion-paper
              (if (and virtual-p (= operation "REPLACE"))
                (fra:find-companion-paper-insert frame spec)
                nil))
            (setq base-log-row
              (list
                "" (getvar "DWGNAME") (fra:get 5 fdata)
                (if loose-layout-p
                  (strcat "LOOSE_LAYOUT_FRAME_" (car spec))
                  (fra:get 2 fdata))
                (if title (fra:get 5 tdata) "")
                (fra:p point)
                (fra:n sx) (fra:aval "图名" oldattrs)
                (fra:aval "图号" oldattrs)
                (if (= operation "REPLACE")
                  (strcat
                    (car spec) " -> " (car spec)
                    "; name-independent geometry match; scale preserved")
                  (if virtual-p
                    (strcat (car spec)
                      "; XREF preserved; host overlay updates drawing name/number")
                    (strcat (car spec)
                      "; title attributes updated; frame preserved"))
                )
                (fra:layout-name frame)
                (fra:p title-point)
                (fra:n sy)
                (fra:n rotation)
                (car spec)
                (if virtual-p "1" "0")
                (itoa preserved-signature-count)
                (if loose-layout-p
                  (fra:join-entity-handles loose-layout-cleanup)
                  (if companion-paper
                    (fra:s (fra:get 5 (entget companion-paper))) ""))
              )
            )
            (if (and (not dry-run) missing-required)
              (progn
                (setq skipped (1+ skipped))
                (fra:write-log log-file
                  (list "ERROR" (getvar "DWGNAME")
                    (fra:get 5 fdata) (fra:get 2 fdata)
                    (if title (fra:get 5 tdata) "")
                    (fra:p point) (fra:n sx)
                    (fra:aval "图名" oldattrs)
                    (fra:aval "图号" oldattrs)
                    (strcat
                      "CFR-E106 Required title field missing: "
                      (if (= (fra:aval "图名" values) "") "图名 " "")
                      (if (= (fra:aval "图号" values) "") "图号" "")
                      "; source frame kept")))
              )
              (if dry-run
              (progn
                (setq replaced (1+ replaced))
                (setq base-log-row (cons "PLANNED" (cdr base-log-row)))
                (fra:write-log log-file
                  (append
                    base-log-row
                    (fra:values-for-tags editable-tags values)
                  )
                )
              )
              (progn
                (if (/= (strcase (getvar "CTAB"))
                        (strcase (fra:layout-name frame)))
                  (setvar "CTAB" (fra:layout-name frame))
                )
                (if (= operation "UPDATE_TITLE")
                  (if virtual-p
                    (progn
                      ;; A true WIPEOUT is required for nested Tianzheng proxy
                      ;; text.  Create it first, then insert the new attributes
                      ;; so the new values remain above the mask.
                      (setq masks-ok
                        (fra:make-xref-global-wipeouts frame spec values))
                      (setq overlay
                        (if masks-ok
                          (fra:upsert-xref-title-overlay
                            frame title-point sx sy rotation values)
                          nil)
                      )
                      (if overlay
                        (progn
                          ;; The recovery stage records the exact, per-sheet
                          ;; entities that display the old DWG NAME / DWG NO.
                          ;; Delete those two entities only after the host-local
                          ;; replacement overlay has been inserted successfully.
                          (fra:delete-proxy-title-handles values)
                          (setq replaced (1+ replaced))
                          (setq base-log-row
                            (cons "UPDATED" (cdr base-log-row)))
                          (fra:write-log log-file
                            (append base-log-row
                              (fra:values-for-tags editable-tags values)))
                        )
                        (progn
                          (setq skipped (1+ skipped))
                          (fra:write-log log-file
                            (list "ERROR" (getvar "DWGNAME")
                              (fra:get 5 fdata) (fra:get 2 fdata) ""
                              (fra:p point) (fra:n sx)
                              (fra:aval "图名" oldattrs)
                              (fra:aval "图号" oldattrs)
                              "XREF title overlay insert failed"))
                        )
                      )
                    )
                    (progn
                      (setq title-sx
                        (if (numberp (fra:get 41 tdata))
                          (fra:get 41 tdata) 1.0))
                      (setq title-sy
                        (if (numberp (fra:get 42 tdata))
                          (fra:get 42 tdata) 1.0))
                      (setq title-rotation
                        (if (numberp (fra:get 50 tdata))
                          (fra:get 50 tdata) 0.0))
                      (setq signature-result
                        (fra:insert-signatures
                          title values title-sx title-sy title-rotation))
                      (setq signatures-ok (car signature-result))
                      (setq inserted-signatures (cadr signature-result))
                      (if signatures-ok
                        (progn
                          (fra:set-attributes title (fra:original-title-geometry values title))
                          (setq replaced (1+ replaced))
                          (setq base-log-row
                            (cons "UPDATED" (cdr base-log-row)))
                          (fra:write-log log-file
                            (append base-log-row
                              (fra:values-for-tags editable-tags values)))
                        )
                        (progn
                          (fra:delete-entities inserted-signatures)
                          (setq skipped (1+ skipped))
                          (fra:write-log log-file
                            (list "ERROR" (getvar "DWGNAME")
                              (fra:get 5 fdata) (fra:get 2 fdata)
                              (fra:get 5 tdata) (fra:p point)
                              (fra:n sx) (fra:aval "图名" oldattrs)
                              (fra:aval "图号" oldattrs)
                              (strcat "Title/signature update failed; "
                                fra:last-signature-error)))
                        )
                      )
                    )
                  )
                  (progn
                    (setq new-frame
                      (fra:insert
                        border-library border-name point sx sy rotation)
                    )
                    (setq new-title
                      (if new-frame
                        (fra:insert
                          title-library title-name title-point title-sx title-sy title-rotation)
                        nil
                      )
                    )
                    (setq signature-result (list nil nil))
                    (setq preserved-result (list T nil))
                    (if (and new-frame new-title)
                      (progn
                        (fra:set-attributes new-title
                          (fra:original-title-geometry values
                            (if (and title (not virtual-p) (not loose-layout-p)) title nil)))
                        (setq signature-result
                          (fra:insert-signatures
                            new-title values title-sx title-sy title-rotation)
                        )
                        (if (and virtual-p (car signature-result))
                          (progn
                            (setq new-title-layer
                              (fra:s (fra:get 8 (entget new-title)))
                            )
                            (setq preserved-result
                              (fra:preserve-xref-signatures
                                frame spec values new-title-layer)
                            )
                          )
                        )
                      )
                    )
                    (setq signatures-ok (car signature-result))
                    (setq inserted-signatures (cadr signature-result))
                    (setq preserved-ok (car preserved-result))
                    (setq preserved-signatures (cadr preserved-result))
                    (if (and new-frame new-title signatures-ok preserved-ok)
                      (progn
                        (fra:delete-proxy-title-handles values)
                        (if loose-layout-p
                          (fra:delete-entities loose-layout-cleanup)
                          (progn
                            (entdel frame)
                            (if (and title (not virtual-p)) (entdel title))))
                        (if companion-paper (entdel companion-paper))
                        (setq replaced (1+ replaced))
                        (setq base-log-row
                          (cons "REPLACED" (cdr base-log-row))
                        )
                        (fra:write-log log-file
                          (append
                            base-log-row
                            (fra:values-for-tags editable-tags values)
                          )
                        )
                      )
                      (progn
                        (fra:delete-entities inserted-signatures)
                        (fra:delete-entities preserved-signatures)
                        (if new-frame (entdel new-frame))
                        (if new-title (entdel new-title))
                        (setq skipped (1+ skipped))
                        (fra:write-log log-file
                          (list "ERROR" (getvar "DWGNAME")
                            (fra:get 5 fdata) (fra:get 2 fdata)
                            (fra:get 5 tdata) (fra:p point)
                            (fra:n sx) (fra:aval "图名" oldattrs)
                            (fra:aval "图号" oldattrs)
                            (strcat
                              "Frame/title/signature insert failed; "
                              "old frame kept; "
                              fra:last-frame-insert-error "; "
                              fra:last-signature-error))
                        )
                      )
                    )
                  )
                )
              )
              )
            )
          )
        )
      )
      (setq replace-ms
        (fra:ms-diff (getvar "MILLISECS") replace-start)
      )
      (setvar "OSMODE" old-osmode)
      (setvar "AUNITS" old-aunits)
      (setvar "ANGBASE" old-angbase)
      (setvar "ANGDIR" old-angdir)
      (setvar "INSUNITS" old-insunits)
      (if (/= (strcase (getvar "CTAB")) (strcase old-ctab))
        (setvar "CTAB" old-ctab)
      )
      ;; Even a deliberately skipped file must be saved in the isolated temp
      ;; copy.  Otherwise Core Console can stop at QUIT waiting for a save
      ;; response, preventing the batch from continuing to the next DWG.
      (if (and (not dry-run) (or (> replaced 0) (> skipped 0)))
        (progn
          (setq save-start (getvar "MILLISECS"))
          ;; Rebuild aligned ATTRIB display data before saving.  Without a
          ;; regeneration, some AutoCAD/Tianzheng drawings reopen with a
          ;; complete 图名 value in Properties but render it as a point.
          (command "_.REGENALL")
          (command "_.QSAVE")
          (setq save-ms
            (fra:ms-diff (getvar "MILLISECS") save-start)
          )
        )
      )
    )
  )
  (fra:write-log log-file
    (list "SUMMARY" (getvar "DWGNAME") "" "" "" "" "" "" ""
      (strcat "replaced=" (itoa replaced) ";skipped=" (itoa skipped)
        ";dry_run=" (if dry-run "1" "0")
        ";candidates=" (itoa (length candidates))
        ";titles=" (itoa (length titles))
        ";pairs=" (itoa (length pairs))
        ";title_only=" (itoa title-only-count)
        ";virtual_xrefs=" (itoa (length virtual-pairs))
        ";ambiguous=" (itoa (length ambiguous))
        ";collect_ms=" (itoa collect-ms)
        ";replace_ms=" (itoa replace-ms)
        ";save_ms=" (itoa save-ms))
    )
  )
  (close log-file)
  (princ
    (strcat "\nFRAME_REPLACE_COMPLETE|"
      (itoa replaced) "|" (itoa skipped) "|" (if dry-run "DRY_RUN" "WRITE"))
  )
  (princ)
)

(princ)

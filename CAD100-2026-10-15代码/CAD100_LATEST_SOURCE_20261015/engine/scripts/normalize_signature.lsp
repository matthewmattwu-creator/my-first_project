(vl-load-com)

(defun sig:n (value)
  (if (numberp value) (rtos value 2 8) ""))

(defun sig:write-result (status message / path file)
  (setq path (getenv "FRAME_SIGNATURE_NORMALIZE_RESULT"))
  (if (and path (/= path ""))
    (progn
      (setq file (open path "w" "utf8"))
      (if file
        (progn
          (write-line (strcat status "\t" message) file)
          (close file))))))

(defun c:NORMALIZESIGNATURE
  (/ old-osmode selection lower upper width height center fit)
  (setq old-osmode (getvar "OSMODE"))
  (setvar "CMDECHO" 0)
  (setvar "FILEDIA" 0)
  (setvar "OSMODE" 0)
  (command "_.UCS" "_W")
  (setq selection (ssget "_X" '((410 . "Model"))))
  (if (null selection)
    (sig:write-result "ERROR" "Signature drawing has no model-space entities")
    (progn
      (command "_.REGENALL")
      (setq lower (getvar "EXTMIN"))
      (setq upper (getvar "EXTMAX"))
      (setq width (- (car upper) (car lower)))
      (setq height (- (cadr upper) (cadr lower)))
      (if (or (< width 0.000001) (< height 0.000001))
        (sig:write-result "ERROR" "Signature drawing extents are empty or zero-size")
        (progn
          (setq center
            (list
              (/ (+ (car lower) (car upper)) 2.0)
              (/ (+ (cadr lower) (cadr upper)) 2.0)
              0.0))
          ;; The destination cell is 25 x 8 units. 22 x 6 leaves a safe margin.
          (setq fit (min (/ 22.0 width) (/ 6.0 height)))
          (command
            "_.MOVE"
            selection
            ""
            "_non"
            center
            "_non"
            '(0.0 0.0 0.0))
          (command
            "_.SCALE"
            selection
            ""
            "_non"
            '(0.0 0.0 0.0)
            fit)
          (setvar "INSBASE" '(0.0 0.0 0.0))
          (setvar "INSUNITS" 0)
          (command "_.QSAVE")
          (sig:write-result
            "OK"
            (strcat
              "width=" (sig:n width)
              ";height=" (sig:n height)
              ";scale=" (sig:n fit)))))))
  (setvar "OSMODE" old-osmode)
  (princ))

(c:NORMALIZESIGNATURE)

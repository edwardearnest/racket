#lang racket/base

(define oprintf
  (let ([op (current-output-port)])
    (λ args
      (apply fprintf op args))))

(require mred
         racket/class
         syntax/moddep
         syntax/toplevel
         framework/framework
         string-constants
         mrlib/graph
         drracket/private/drsig
         "eval-helpers.rkt"
         racket/unit
         racket/async-channel
         setup/private/lib-roots
         racket/port
         "rectangle-intersect.rkt")

(define-struct req (filename key))
;; type req = (make-req string[filename] (union symbol #f))

(provide module-overview@
         process-program-unit
         process-program-import^
         process-program-export^
         (struct-out req))

(define adding-file (string-constant module-browser-adding-file))
(define unknown-module-name "? unknown module name")

;; probably, at some point, the module browser should get its
;; own output ports or something instead of wrapping these ones
(define original-output-port (current-output-port))
(define original-error-port (current-error-port))

(define-unit module-overview@
  (import [prefix drracket:frame: drracket:frame^]
          [prefix drracket:eval: drracket:eval^]
          [prefix drracket:language-configuration: drracket:language-configuration/internal^]
          [prefix drracket:language: drracket:language^])
  (export drracket:module-overview^)
  
  (define filename-constant (string-constant module-browser-filename-format))
  (define font-size-gauge-label (string-constant module-browser-font-size-gauge-label))
  (define progress-label (string-constant module-browser-progress-label))
  (define laying-out-graph-label (string-constant module-browser-laying-out-graph-label))
  (define open-file-format (string-constant module-browser-open-file-format))
  (define lib-paths-checkbox-constant (string-constant module-browser-show-lib-paths))
  
  (define (set-box/f b v) (when (box? b) (set-box! b v)))
  
  (define (module-overview parent)
    (let ([filename (get-file #f parent)])
      (when filename
        (module-overview/file filename parent))))
  
  (define (find-label-font size)
    (send the-font-list find-or-create-font size 'decorative 'normal 'normal #f))
  
  (define module-overview-pasteboard<%>
    (interface ()
      set-label-font-size
      get-label-font-size
      get-hidden-paths
      show-visible-paths
      remove-visible-paths
      set-name-length
      get-name-length))
  
  (define boxed-word-snip<%>
    (interface ()
      get-filename
      get-word
      get-lines
      is-special-key-child?
      add-special-key-child
      set-found!))
  
  ;; make-module-overview-pasteboard : boolean
  ;;                                   ((union #f snip) -> void)
  ;;                                -> (union string pasteboard)
  ;; string as result indicates an error message
  ;; pasteboard as result is the pasteboard to show
  (define (make-module-overview-pasteboard vertical? mouse-currently-over)
    
    (define level-ht (make-hasheq))
    
    ;; snip-table : hash-table[sym -o> snip]
    (define snip-table (make-hash))
    (define label-font (find-label-font (preferences:get 'drracket:module-overview:label-font-size)))
    (define text-color "blue")
    
    (define search-result-text-color "white")
    (define search-result-background "forestgreen")
    
    (define dark-syntax-pen (send the-pen-list find-or-create-pen "darkorchid" 1 'solid))
    (define dark-syntax-brush (send the-brush-list find-or-create-brush "darkorchid" 'solid))
    (define light-syntax-pen (send the-pen-list find-or-create-pen "plum" 1 'solid))
    (define light-syntax-brush (send the-brush-list find-or-create-brush "plum" 'solid))
    
    (define dark-template-pen (send the-pen-list find-or-create-pen "seagreen" 1 'solid))
    (define dark-template-brush (send the-brush-list find-or-create-brush "seagreen" 'solid))
    (define light-template-pen (send the-pen-list find-or-create-pen "springgreen" 1 'solid))
    (define light-template-brush (send the-brush-list find-or-create-brush "springgreen" 'solid))
    
    (define dark-pen (send the-pen-list find-or-create-pen "blue" 1 'solid))
    (define dark-brush (send the-brush-list find-or-create-brush "blue" 'solid))
    (define light-pen (send the-pen-list find-or-create-pen "light blue" 1 'solid))
    (define light-brush (send the-brush-list find-or-create-brush "light blue" 'solid))
    
    (define (module-overview-pasteboard-mixin %)
      (class* % (module-overview-pasteboard<%>)
        
        (inherit get-snip-location
                 begin-edit-sequence
                 end-edit-sequence
                 insert
                 move-to
                 find-first-snip
                 dc-location-to-editor-location
                 find-snip
                 get-canvas)
      
        ;; require-depth-ht : hash[(list snip snip) -o> (listof integer)]
        ;; maps parent/child snips (ie, those that match up to modules 
        ;; that require each other) to phase differences
        (define require-depth-ht (make-hash))
        
        (define name-length 'long)
        (define/public (set-name-length nl)
          (unless (eq? name-length nl)
            (set! name-length nl)
            (re-add-snips)
            (render-snips)))
        (define/public (get-name-length) name-length)
        
        (field [max-lines #f])
        
        ;; controls if the snips should be moved
        ;; around when the font size is changed.
        ;; set to #f if the user ever moves a
        ;; snip themselves.
        (define dont-move-snips #f)
        
        (field (label-font-size (preferences:get 'drracket:module-overview:label-font-size)))
        (define/public (get-label-font-size) label-font-size)
        (define/private (get-snip-hspace) (if vertical?
                                              2
                                              (* 2 label-font-size)))
        (define/private (get-snip-vspace) (if vertical?
                                              30
                                              2))
        (define snip-height #f)
        
        (define font-label-size-callback-running? #f)
        (define new-font-size #f)
        (define/public (set-label-font-size size-to-set)
          (set! new-font-size size-to-set)
          (unless font-label-size-callback-running?
            (set! font-label-size-callback-running? #t)
            (queue-callback
             (λ ()
               (set! label-font-size new-font-size)
               (preferences:set 'drracket:module-overview:label-font-size 
                                new-font-size)
               (set! label-font (find-label-font label-font-size))
               (begin-edit-sequence)
               (let loop ([snip (find-first-snip)])
                 (when snip
                   (let ([admin (send snip get-admin)])
                     (when admin
                       (send admin resized snip #t)))
                   (loop (send snip next))))
               (unless dont-move-snips
                 (render-snips))
               (end-edit-sequence)
               (set! new-font-size #f)
               (set! font-label-size-callback-running? #f))
             #f)))
        
        (define/public (begin-adding-connections)
          (when max-lines
            (error 'begin-adding-connections
                   "already in begin-adding-connections/end-adding-connections sequence"))
          (set! max-lines 0)
          (begin-edit-sequence)
          (let loop ()
            (let ([s (find-first-snip)])
              (when s
                (send s release-from-owner)
                (loop))))
          (set! level-ht (make-hasheq))
          (set! snip-table (make-hash)))
        
        (define/public (end-adding-connections)
          (unless max-lines
            (error 'end-adding-connections
                   "not in begin-adding-connections/end-adding-connections sequence"))
          
          (unless (zero? max-lines)
            (let loop ([snip (find-first-snip)])
              (when snip
                (when (is-a? snip word-snip/lines%)
                  (send snip normalize-lines max-lines))
                (loop (send snip next)))))
          
          
          (set! max-lines #f)
          (compute-snip-require-phases)
          (remove-specially-linked)
          (render-snips)
          (end-edit-sequence))
        
        (define/private (compute-snip-require-phases)
          (let ([ht (make-hash)]) ;; avoid infinite loops 
            (for ([snip (in-list (get-top-most-snips))])
              (let loop ([parent snip]
                         [depth 0])    ;; depth is either an integer or #f (indicating for-label)
                (unless (hash-ref ht (cons parent depth) #f)
                  (hash-set! ht (cons parent depth) #t)
                  (send parent add-require-phase depth)
                  (for ([child (in-list (send parent get-children))])
                    (for ([delta-depth (in-list (hash-ref require-depth-ht (list parent child)))])
                      (loop child 
                            (and depth delta-depth (+ delta-depth depth))))))))))
        
        ;; add-connection : string string (union symbol #f) number -> void
        ;; name-original and name-require and the identifiers for those paths and
        ;; original-filename? and require-filename? are booleans indicating if the names
        ;; are filenames.
        (define/public (add-connection name-original name-require path-key require-depth)
          (unless max-lines
            (error 'add-connection "not in begin-adding-connections/end-adding-connections sequence"))
          (let* ([original-filename? (file-exists? name-original)]
                 [require-filename? (file-exists? name-require)]
                 [original-snip (find/create-snip name-original original-filename?)]
                 [require-snip (find/create-snip name-require require-filename?)]
                 [original-level (send original-snip get-level)]
                 [require-level (send require-snip get-level)])
            (let ([require-depth-key (list original-snip require-snip)])
              (hash-set! require-depth-ht 
                         require-depth-key
                         (cons require-depth (hash-ref require-depth-ht require-depth-key '())))) 
            (case require-depth 
              [(0)
               (add-links original-snip require-snip
                          dark-pen light-pen
                          dark-brush light-brush)]
              [else
               (add-links original-snip require-snip 
                          dark-syntax-pen light-syntax-pen
                          dark-syntax-brush light-syntax-brush)])
            (when path-key
              (send original-snip add-special-key-child path-key require-snip))
            (if (send original-snip get-level)
                (fix-snip-level require-snip (+ original-level 1))
                (fix-snip-level original-snip 0))))
        
        ;; fix-snip-level : snip number -> void
        ;; moves the snip (and any children) to at least `new-level'
        ;; doesn't move them if they are already past that level
        (define/private (fix-snip-level snip new-min-level)
          (let loop ([snip snip]
                     [new-min-level new-min-level])
            (let ([current-level (send snip get-level)])
              (when (or (not current-level)
                        (new-min-level . > . current-level))
                (send snip set-level new-min-level)
                (for-each
                 (λ (child) (loop child (+ new-min-level 1)))
                 (send snip get-children))))))
        
        ;; find/create-snip : (union path string) boolean? -> word-snip/lines
        ;; finds the snip with this key, or creates a new
        ;; ones. For the same key, always returns the same snip.
        ;; uses snip-table as a cache for this purpose.
        (define/private (find/create-snip name is-filename?)
          (hash-ref
           snip-table
           name
           (λ () 
             (let* ([snip (instantiate word-snip/lines% ()
                            (lines (if is-filename? (count-lines name) #f))
                            (word (let-values ([(_1 name _2) (split-path name)])
                                    (path->string name)))
                            (pb this)
                            (filename (if is-filename? name #f)))])
               (insert snip)
               (hash-set! snip-table name snip)
               snip))))
        
        ;; count-lines : string[filename] -> (union #f number)
        ;; effect: updates max-lines
        (define/private (count-lines filename)
          (let ([lines
                 (call-with-input-file filename
                   (λ (port)
                     (let loop ([n 0])
                       (let ([l (read-line port)])
                         (if (eof-object? l)
                             n
                             (loop (+ n 1))))))
                   #:mode 'text)])
            (set! max-lines (max lines max-lines))
            lines))
        
        ;; get-snip-width : snip -> number
        ;; exracts the width of a snip
        (define/private (get-snip-width snip)
          (let ([lb (box 0)]
                [rb (box 0)])
            (get-snip-location snip lb #f #f)
            (get-snip-location snip rb #f #t)
            (- (unbox rb)
               (unbox lb))))
        
        ;; get-snip-height : snip -> number
        ;; exracts the width of a snip
        (define/private (get-snip-height snip)
          (let ([tb (box 0)]
                [bb (box 0)])
            (get-snip-location snip #f tb #f)
            (get-snip-location snip #f bb #t)
            (- (unbox bb)
               (unbox tb))))
        
        (field [hidden-paths (preferences:get 'drracket:module-browser:hide-paths)])
        (define/public (remove-visible-paths symbol)
          (unless (memq symbol hidden-paths)
            (set! hidden-paths (cons symbol hidden-paths))
            (refresh-visible-paths)))
        (define/public (show-visible-paths symbol)
          (when (memq symbol hidden-paths)
            (set! hidden-paths (remq symbol hidden-paths))
            (refresh-visible-paths)))
        (define/public (get-hidden-paths) hidden-paths)
        
        (define/private (refresh-visible-paths)
          (begin-edit-sequence)
          (re-add-snips)
          (render-snips)
          (end-edit-sequence))
        
        (define/private (re-add-snips)
          (begin-edit-sequence)
          (remove-specially-linked)
          (end-edit-sequence))
        
        (define/private (remove-specially-linked)
          (remove-currrently-inserted)
          (cond
            [(null? hidden-paths)
             (add-all)]
            [else
             (let ([ht (make-hasheq)])
               (for ([snip (in-list (get-top-most-snips))])
                 (insert snip)
                 (let loop ([snip snip])
                   (unless (hash-ref ht snip #f)
                     (hash-set! ht snip #t)
                     (for ([child (in-list (send snip get-children))])
                       (unless (ormap (λ (key) (send snip is-special-key-child?
                                                     key child))
                                      hidden-paths)
                         (insert child)
                         (loop child)))))))]))
        
        (define/private (remove-currrently-inserted)
          (let loop ()
            (let ([snip (find-first-snip)])
              (when snip
                (send snip release-from-owner)
                (loop)))))
        
        (define/private (add-all)
          (let ([ht (make-hasheq)])
            (for-each
             (λ (snip)
               (let loop ([snip snip])
                 (unless (hash-ref ht snip (λ () #f))
                   (hash-set! ht snip #t)
                   (insert snip)
                   (for-each loop (send snip get-children)))))
             (get-top-most-snips))))
        
        (define/private (get-top-most-snips) (hash-ref level-ht 0 (λ () null)))
        
        ;; render-snips : -> void
        (define/public (render-snips)
          (begin-edit-sequence)
          (let ([max-minor 0])
            
            ;; major-dim is the dimension that new levels extend along
            ;; minor-dim is the dimension that snips inside a level extend along
            
            (hash-for-each
             level-ht
             (λ (n v)
               (set! max-minor (max max-minor (apply + (map (if vertical?
                                                                (λ (x) (get-snip-width x))
                                                                (λ (x) (get-snip-height x)))
                                                            v))))))
            
            (let ([levels (sort (hash-map level-ht list)
                                (λ (x y) (<= (car x) (car y))))])
              (let loop ([levels levels]
                         [major-dim 0])
                (cond
                  [(null? levels) (void)]
                  [else
                   (let* ([level (car levels)]
                          [n (car level)]
                          [this-level-snips (cadr level)]
                          [this-minor (apply + (map (if vertical? 
                                                        (λ (x) (get-snip-width x))
                                                        (λ (x) (get-snip-height x)))
                                                    this-level-snips))]
                          [this-major (apply max (map (if vertical? 
                                                          (λ (x) (get-snip-height x))
                                                          (λ (x) (get-snip-width x)))
                                                      this-level-snips))])
                     (let loop ([snips this-level-snips]
                                [minor-dim (/ (- max-minor this-minor) 2)])
                       (unless (null? snips)
                         (let* ([snip (car snips)]
                                [new-major-coord
                                 (+ major-dim
                                    (floor
                                     (- (/ this-major 2) 
                                        (/ (if vertical? 
                                               (get-snip-height snip)
                                               (get-snip-width snip))
                                           2))))])
                           (if vertical?
                               (move-to snip minor-dim new-major-coord)
                               (move-to snip new-major-coord minor-dim))
                           (loop (cdr snips)
                                 (+ minor-dim
                                    (if vertical?
                                        (get-snip-hspace)
                                        (get-snip-vspace))
                                    (if vertical?
                                        (get-snip-width snip)
                                        (get-snip-height snip)))))))
                     (loop (cdr levels)
                           (+ major-dim 
                              (if vertical? 
                                  (get-snip-vspace)
                                  (get-snip-hspace))
                              this-major)))]))))
          (end-edit-sequence))
        
        (define/override (on-mouse-over-snips snips)
          (mouse-currently-over snips))
        
        (define/override (on-double-click snip event)
          (cond
            [(is-a? snip boxed-word-snip<%>) 
             (let ([fn (send snip get-filename)])
               (when fn
                 (handler:edit-file fn)))]
            [else (super on-double-click snip event)]))
        
        (define/override (on-event evt)
          (cond
            [(send evt button-down? 'right)
             (let ([ex (send evt get-x)]
                   [ey (send evt get-y)])
               (let-values ([(x y) (dc-location-to-editor-location ex ey)])
                 (let ([snip (find-snip x y)]
                       [canvas (get-canvas)])
                   (let ([right-button-menu (make-object popup-menu%)])
                     (when (and snip
                                (is-a? snip boxed-word-snip<%>)
                                canvas
                                (send snip get-filename))
                       (instantiate menu-item% ()
                         (label 
                          (trim-string
                           (format open-file-format
                                   (path->string (send snip get-filename)))
                           200))
                         (parent right-button-menu)
                         (callback
                          (λ (x y)
                            (handler:edit-file
                             (send snip get-filename))))))
                     (instantiate menu-item% ()
                       (label (string-constant module-browser-open-all))
                       (parent right-button-menu)
                       (callback
                        (λ (x y)
                          (let loop ([snip (find-first-snip)])
                            (when snip
                              (when (is-a? snip boxed-word-snip<%>)
                                (let ([filename (send snip get-filename)])
                                  (handler:edit-file filename)))
                              (loop (send snip next)))))))
                     (send canvas popup-menu
                           right-button-menu
                           (+ (send evt get-x) 1)
                           (+ (send evt get-y) 1))))))]
            [else (super on-event evt)]))
        
        (super-new)))
    
    (define (trim-string str len)
      (cond
        [(<= (string-length str) len) str]
        [else (substring str (- (string-length str) len) (string-length str))]))
    
    (define (level-mixin %)
      (class %
        (field (level #f))
        (define/public (get-level) level)
        (define/public (set-level _l) 
          (when level
            (hash-set! level-ht level
                       (remq this (hash-ref level-ht level))))
          (set! level _l)
          (hash-set! level-ht level 
                     (cons this (hash-ref level-ht level (λ () null)))))
        
        (super-instantiate ())))
    
    (define (boxed-word-snip-mixin %)
      (class* % (boxed-word-snip<%>)
        (init-field word
                    filename
                    lines
                    pb)
        
        (inherit get-admin)
        
        (define require-phases '())
        (define/public (add-require-phase d)
          (unless (member d require-phases)
            (set! last-name #f)
            (set! last-size #f)
            (set! require-phases (sort (cons d require-phases) < #:key (λ (x) (or x +inf.0))))))
        
        (field [special-children (make-hasheq)])
        (define/public (is-special-key-child? key child)
          (let ([ht (hash-ref special-children key #f)])
            (and ht (hash-ref ht child #f))))
        (define/public (add-special-key-child key child)
          (hash-set! (hash-ref! special-children key make-hasheq) child #t))
        
        (define/public (get-filename) filename)
        (define/public (get-word) word)
        (define/public (get-lines) lines)
        
        (field (lines-brush #f))
        (define/public (normalize-lines n)
          (if lines
              (let* ([grey (inexact->exact (floor (- 255 (* 255 (sqrt (/ lines n))))))])
                (set! lines-brush (send the-brush-list find-or-create-brush
                                        (make-object color% grey grey grey)
                                        'solid)))
              (set! lines-brush (send the-brush-list find-or-create-brush
                                      "salmon"
                                      'solid))))
        
        (define snip-width 0)
        (define snip-height 0)
        
        (define/override (get-extent dc x y wb hb descent space lspace rspace)
          (cond
            [(equal? (name->label) "")
             (set! snip-width 15)
             (set! snip-height 15)]
            [else
             (let-values ([(w h a d) (send dc get-text-extent (name->label) label-font)])
               (set! snip-width (+ w 5))
               (set! snip-height (+ h 5)))])
          (set-box/f wb snip-width)
          (set-box/f hb snip-height)
          (set-box/f descent 0)
          (set-box/f space 0)
          (set-box/f lspace 0)
          (set-box/f rspace 0))
        
        (define/public (set-found! fh?) 
          (unless (eq? (and fh? #t) found-highlight?)
            (set! found-highlight? (and fh? #t))
            (let ([admin (get-admin)])
              (when admin
                (send admin needs-update this 0 0 snip-width snip-height)))))
        (define found-highlight? #f)
        
        (define/override (draw dc x y left top right bottom dx dy draw-caret)
          (let ([old-font (send dc get-font)]
                [old-text-foreground (send dc get-text-foreground)]
                [old-brush (send dc get-brush)]
                [old-pen (send dc get-pen)])
            (send dc set-font label-font)
            (cond
              [found-highlight?
               (send dc set-brush search-result-background 'solid)]
              [lines-brush
               (send dc set-brush lines-brush)])
            (when (rectangles-intersect? left top right bottom
                                         x y (+ x snip-width) (+ y snip-height))
              (send dc draw-rectangle x y snip-width snip-height)
              (send dc set-text-foreground (send the-color-database find-color 
                                                 (if found-highlight?
                                                     search-result-text-color
                                                     text-color)))
              (send dc draw-text (name->label) (+ x 2) (+ y 2)))
            (send dc set-pen old-pen)
            (send dc set-brush old-brush)
            (send dc set-text-foreground old-text-foreground)
            (send dc set-font old-font)))
        
        ;; name->label : path -> string
        ;; constructs a label for the little boxes in terms
        ;; of the filename.
        
        (define last-name #f)
        (define last-size #f)
        
        (define/private (name->label)
          (let ([this-size (send pb get-name-length)])
            (cond
              [(eq? this-size last-size) last-name]
              [else
               (set! last-size this-size)
               (set! last-name
                     (case last-size
                       [(short)
                        (if (string=? word "")
                            ""
                            (string (string-ref word 0)))]
                       [(medium)
                        (let ([m (regexp-match #rx"^(.*)\\.[^.]*$" word)])
                          (let ([short-name (if m (cadr m) word)])
                            (if (string=? short-name "")
                                ""
                                (let ([ms (regexp-match* #rx"-[^-]*" short-name)])
                                  (cond
                                    [(null? ms)
                                     (substring short-name 0 (min 2 (string-length short-name)))]
                                    [else
                                     (apply string-append
                                            (cons (substring short-name 0 1)
                                                  (map (λ (x) (substring x 1 2))
                                                       ms)))])))))]
                       [(long) word]
                       [(very-long)  
                        (string-append
                         word
                         ": "
                         (format "~s" require-phases))]))
               last-name])))
        
        (super-new)))
    
    (define word-snip/lines% (level-mixin (boxed-word-snip-mixin (graph-snip-mixin snip%))))
    
    (define draw-lines-pasteboard% (module-overview-pasteboard-mixin
                                    (graph-pasteboard-mixin
                                     pasteboard:basic%)))
    (new draw-lines-pasteboard% [cache-arrow-drawing? #t]))
  
  
  ;                                                                
  ;                                                                
  ;                                                                
  ;    ;;;                                      ;;;;   ;     ;  ;  
  ;   ;                                        ;    ;  ;     ;  ;  
  ;   ;                                       ;        ;     ;  ;  
  ;  ;;;;  ; ;  ;;;    ; ;;  ;;     ;;;       ;        ;     ;  ;  
  ;   ;    ;;  ;   ;   ;;  ;;  ;   ;   ;      ;        ;     ;  ;  
  ;   ;    ;       ;   ;   ;   ;  ;    ;      ;        ;     ;  ;  
  ;   ;    ;    ;;;;   ;   ;   ;  ;;;;;;      ;     ;  ;     ;  ;  
  ;   ;    ;   ;   ;   ;   ;   ;  ;           ;     ;  ;     ;  ;  
  ;   ;    ;   ;   ;   ;   ;   ;   ;           ;    ;  ;     ;  ;  
  ;   ;    ;    ;;;;;  ;   ;   ;    ;;;;        ;;;;;   ;;;;;   ;  
  ;                                                                
  ;                                                                
  ;                                                                
  
  
  (define (module-overview/file filename parent)
    (define progress-eventspace (make-eventspace))
    (define progress-frame (parameterize ([current-eventspace progress-eventspace])
                             (instantiate frame% ()
                               (parent parent)
                               (label progress-label)
                               (width 600))))
    (define progress-message (instantiate message% ()
                               (label "")
                               (stretchable-width #t)
                               (parent progress-frame)))
    
    (define thd 
      (thread
       (λ ()
         (sleep 2)
         (parameterize ([current-eventspace progress-eventspace])
           (queue-callback
            (λ ()
              (send progress-frame show #t)))))))
    
    (define text/pos 
      (let ([t (make-object text:basic%)])
        (send t load-file filename)
        (drracket:language:text/pos
         t
         0
         (send t last-position))))
    
    (define update-label void)
    
    (define (show-status str)
      (parameterize ([current-eventspace progress-eventspace])
        (queue-callback
         (λ ()
           (send progress-message set-label str)))))
    
    (define pasteboard (make-module-overview-pasteboard 
                        #f
                        (λ (x) (update-label x))))
    
    (let ([success? (fill-pasteboard pasteboard text/pos show-status void)])
      (kill-thread thd)
      (parameterize ([current-eventspace progress-eventspace])
        (queue-callback
         (λ ()
           (send progress-frame show #f))))
      (when success?
        (let ()
          (define frame (instantiate overview-frame% ()
                          (label (string-constant module-browser))
                          (width (preferences:get 'drracket:module-overview:window-width))
                          (height (preferences:get 'drracket:module-overview:window-height))
                          (alignment '(left center))))
          (define vp (instantiate vertical-panel% ()
                       (parent (send frame get-area-container))
                       (alignment '(left center))))
          (define root-message (instantiate message% ()
                                 (label 
                                  (format (string-constant module-browser-root-filename)
                                          filename))
                                 (parent vp)
                                 (stretchable-width #t)))
          (define label-message (instantiate message% ()
                                  (label "")
                                  (parent vp)
                                  (stretchable-width #t)))
          (define font/label-panel (new horizontal-panel%
                                        [parent vp]
                                        [stretchable-height #f]))
          (define font-size-gauge
            (instantiate slider% ()
              (label font-size-gauge-label)
              (min-value 1)
              (max-value 72)
              (init-value (preferences:get 'drracket:module-overview:label-font-size))
              (parent font/label-panel)
              (callback
               (λ (x y)
                 (send pasteboard set-label-font-size (send font-size-gauge get-value))))))
          (define module-browser-name-length-choice
            (new choice%
                 (parent font/label-panel)
                 (label (string-constant module-browser-name-length))
                 (choices (list (string-constant module-browser-name-long)
                                (string-constant module-browser-name-very-long)))
                 (selection (case (preferences:get 'drracket:module-browser:name-length)
                              [(0) 0]
                              [(1) 0]
                              [(2) 0]
                              [(3) 1]))
                 (callback
                  (λ (x y)
                    ;; note: the preference drracket:module-browser:name-length is also used for 
                    ;; the View|Show Module Browser version of the module browser
                    ;; here we just treat any pref value except '3' as if it were for the long names.
                    (let ([selection (send module-browser-name-length-choice get-selection)])
                      (preferences:set 'drracket:module-browser:name-length (+ 2 selection))
                      (send pasteboard set-name-length 
                            (case selection
                              [(0) 'long]
                              [(1) 'very-long])))))))
          
          (define lib-paths-checkbox
            (instantiate check-box% ()
              (label lib-paths-checkbox-constant)
              (parent vp)
              (callback
               (λ (x y)
                 (if (send lib-paths-checkbox get-value)
                     (send pasteboard show-visible-paths 'lib)
                     (send pasteboard remove-visible-paths 'lib))))))
          
          (define ec (make-object canvas:basic% vp pasteboard))
          
          (define search-tf
            (new text-field%
                 [label (string-constant module-browser-highlight)]
                 [parent vp]
                 [callback
                  (λ (tf evt)
                    (send pasteboard begin-edit-sequence)
                    (define val (send tf get-value))
                    (define reg (and (not (string=? val ""))
                                     (regexp (regexp-quote (send tf get-value)))))
                    (let loop ([snip (send pasteboard find-first-snip)])
                      (when snip
                        (when (is-a? snip boxed-word-snip<%>)
                          (send snip set-found! 
                                (and reg (regexp-match reg (path->string (send snip get-filename))))))
                        (loop (send snip next))))
                    (send pasteboard end-edit-sequence))]))
          
          (send lib-paths-checkbox set-value
                (not (memq 'lib (preferences:get 'drracket:module-browser:hide-paths))))
          (set! update-label
                (λ (s)
                  (if (and s (not (null? s)))
                      (let* ([currently-over (car s)]
                             [fn (send currently-over get-filename)]
                             [lines (send currently-over get-lines)])
                        (when (and fn lines)
                          (send label-message set-label
                                (format filename-constant fn lines))))
                      (send label-message set-label ""))))
          
          (send pasteboard set-name-length 
                (case (preferences:get 'drracket:module-browser:name-length)
                  [(0) 'long]
                  [(1) 'long]
                  [(2) 'long]
                  [(3) 'very-long]))          
          ;; shouldn't be necessary here -- need to find callback on editor
          (send pasteboard render-snips)
          
          (send frame show #t)))))
  
  (define (fill-pasteboard pasteboard text/pos show-status send-user-thread/eventspace)
    
    (define progress-channel (make-async-channel))
    (define connection-channel (make-async-channel))
    
    (define-values/invoke-unit process-program-unit
      (import process-program-import^)
      (export process-program-export^))
    
    ;; =user thread=
    (define (iter sexp continue)
      (cond
        [(eof-object? sexp) 
         (custodian-shutdown-all user-custodian)]
        [else
         (add-connections sexp)
         (continue)]))
    (define init-complete (make-semaphore 0))
    
    (define user-custodian #f)
    (define user-thread #f)
    (define error-str #f)
    
    (define init-dir
      (let* ([bx (box #f)]
             [filename (send (drracket:language:text/pos-text text/pos) get-filename bx)])
        (get-init-dir 
         (and (not (unbox bx)) filename))))
    
    (define (init)
      (set! user-custodian (current-custodian))
      (set! user-thread (current-thread))
      (moddep-current-open-input-file
       (λ (filename)
         (let* ([p (open-input-file filename)]
                [wxme? (regexp-match-peek #rx#"^WXME" p)])
           (if wxme?
               (let ([t (new text%)])
                 (close-input-port p)
                 (send t load-file filename)
                 (let ([prt (open-input-text-editor t)])
                   (port-count-lines! prt)
                   prt))
               p))))
      (current-output-port (swallow-specials original-output-port))
      (current-error-port (swallow-specials original-error-port))
      (current-load-relative-directory #f)
      (current-directory init-dir)
      (error-display-handler (λ (str exn) 
                               (set! error-str str)
                               (when (exn? exn)
                                 (set! error-str
                                       (apply
                                        string-append
                                        error-str
                                        (for/list ([x (in-list (continuation-mark-set->context 
                                                                (exn-continuation-marks exn)))])
                                          (format "\n  ~s" x)))))))
      
      ;; instead of escaping when there's an error on the user thread,
      ;; we just shut it all down. This kills the event handling loop
      ;; for the eventspace and wakes up the thread below
      ;; NOTE: we cannot set this directly in `init' since the call to `init'
      ;; is wrapped in a parameterize of the error-escape-handler
      (queue-callback
       (λ ()
         (error-escape-handler
          (λ () (custodian-shutdown-all user-custodian)))
         (semaphore-post init-complete))))
    
    (define (swallow-specials port)
      (define-values (in out) (make-pipe-with-specials))
      (thread
       (λ ()
         (let loop ()
           (define c (read-char-or-special in))
           (cond
             [(char? c)
              (display c out)
              (loop)]
             [(eof-object? c)
              (close-output-port out)
              (close-input-port in)]
             [else
              (loop)]))))
      out)
    
    (define (kill-termination) (void))
    (define complete-program? #t)

    ((drracket:eval:traverse-program/multiple
      (preferences:get (drracket:language-configuration:get-settings-preferences-symbol))
      init
      kill-termination)
     text/pos
     iter
     complete-program?)
    
    (semaphore-wait init-complete)
    (send-user-thread/eventspace user-thread user-custodian)
    
    ;; this thread puts a "cap" on the end of the connection-channel
    ;; so that we know when we've gotten to the end.
    ;; this ensures that we can completely flush out the
    ;; connection-channel.
    (thread
     (λ ()
       (sync (thread-dead-evt user-thread))
       (async-channel-put connection-channel 'done)))
    
    (send pasteboard begin-adding-connections)
    (let ([evt
           (choice-evt
            (handle-evt progress-channel (λ (x) (cons 'progress x)))
            (handle-evt connection-channel (λ (x) (cons 'connect x))))])
      (let loop ()
        (let* ([evt-value (yield evt)]
               [key (car evt-value)]
               [val (cdr evt-value)])
          (case key
            [(progress) 
             (show-status val)
             (loop)]
            [(connect)
             (unless (eq? val 'done)
               (let ([name-original (list-ref val 0)]
                     [name-require (list-ref val 1)]
                     [path-key (list-ref val 2)]
                     [require-depth (list-ref val 3)])
                 (send pasteboard add-connection name-original name-require path-key require-depth))
               (loop))]))))
    (send pasteboard end-adding-connections)
    
    (custodian-shutdown-all user-custodian)
    
    (cond
      [error-str
       (message-box 
        (string-constant module-browser)
        (format (string-constant module-browser-error-expanding)
                error-str))
       #f]
      [else
       #t]))
  
  (define overview-frame%
    (class (drracket:frame:basics-mixin
            frame:standard-menus%)
      (define/override (edit-menu:between-select-all-and-find menu) (void))
      (define/override (edit-menu:between-redo-and-cut menu) (void))
      (define/override (edit-menu:between-find-and-preferences menu) (void))
      
      (define/override (edit-menu:create-cut?) #f)
      (define/override (edit-menu:create-copy?) #f)
      (define/override (edit-menu:create-paste?) #f)
      (define/override (edit-menu:create-clear?) #f)
      (define/override (edit-menu:create-select-all?) #f)
      
      (define/override (on-size w h)
        (preferences:set 'drracket:module-overview:window-width w)
        (preferences:set 'drracket:module-overview:window-height h)
        (super on-size w h))
      (super-instantiate ()))))



;                                                                                    
;                                                                                    
;                                                                                    
;                                                                                    
;                                                                                    
;                                                                                    
;   ; ;;    ; ;   ;;;     ;;;    ;;;    ;;;    ;;;       ; ;;    ; ;   ;;;     ;; ;  
;   ;;  ;   ;;   ;   ;   ;   ;  ;   ;  ;      ;          ;;  ;   ;;   ;   ;   ;  ;;  
;   ;    ;  ;   ;     ; ;      ;    ;  ;;     ;;         ;    ;  ;   ;     ; ;    ;  
;   ;    ;  ;   ;     ; ;      ;;;;;;   ;;     ;;        ;    ;  ;   ;     ; ;    ;  
;   ;    ;  ;   ;     ; ;      ;          ;      ;       ;    ;  ;   ;     ; ;    ;  
;   ;;  ;   ;    ;   ;   ;   ;  ;         ;      ;       ;;  ;   ;    ;   ;   ;  ;;  
;   ; ;;    ;     ;;;     ;;;    ;;;;  ;;;    ;;;        ; ;;    ;     ;;;     ;; ;  
;   ;                                                    ;                        ;  
;   ;                                                    ;                   ;    ;  
;   ;                                                    ;                    ;;;;   


(define-signature process-program-import^
  (progress-channel connection-channel))

(define-signature process-program-export^
  (add-connections))

(define-unit process-program-unit
  (import process-program-import^)
  (export process-program-export^)
  
  (define visited-hash-table (make-hash))
  
  ;; add-connections : (union syntax string[filename]) -> (union #f string)
  ;; recursively adds a connections from this file and
  ;; all files it requires
  ;; returns a string error message if there was an error compiling
  ;; the program
  (define (add-connections filename/stx)
    (cond
      [(path-string? filename/stx)
       (add-filename-connections filename/stx)]
      [(syntax? filename/stx)
       (add-syntax-connections filename/stx)]))
  
  ;; add-syntax-connections : syntax -> void
  (define (add-syntax-connections stx)
    (define module-codes (map compile (expand-syntax-top-level-with-compile-time-evals/flatten stx)))
    (for ([module-code (in-list module-codes)])
      (when (compiled-module-expression? module-code)
        (define name (extract-module-name stx))
        (define base 
          (build-module-filename
           (if (regexp-match #rx"^," name)
               (substring name 1 (string-length name))
               (build-path (or (current-load-relative-directory) 
                               (current-directory))
                           name))
           #f))
        (add-module-code-connections base module-code))))
  
  (define (build-module-filename pth remove-extension?)
    (define (try ext)
      (define tst (bytes->path (bytes-append 
                                (if remove-extension?
                                    (regexp-replace #rx"[.][^.]*$" (path->bytes pth) #"")
                                    (path->bytes pth))
                                ext)))
      (and (file-exists? tst)
           tst))
    (or (try #".rkt")
        (try #".ss")
        (try #".scm")
        (try #"")
        pth))
  
  ;; add-filename-connections : string -> void
  (define (add-filename-connections filename)
    (add-module-code-connections filename (get-module-code filename)))
  
  (define (add-module-code-connections module-name module-code)
    (unless (hash-ref visited-hash-table module-name (λ () #f))
      (async-channel-put progress-channel (format adding-file module-name))
      (hash-set! visited-hash-table module-name #t)
      (define import-assoc (module-compiled-imports module-code))
      (for ([line (in-list import-assoc)])
        (define level (car line))
        (define mpis (cdr line))
        (define requires (extract-filenames mpis module-name))
        (for ([require (in-list requires)])
          (add-connection module-name
                          (req-filename require)
                          (req-key require)
                          level)
          (add-filename-connections (req-filename require))))))
  
  ;; add-connection : string string (union symbol #f) number -> void
  ;; name-original and name-require and the identifiers for those paths and
  ;; original-filename? and require-filename? are booleans indicating if the names
  ;; are filenames.
  (define (add-connection name-original name-require req-sym require-depth)
    (async-channel-put connection-channel
                       (list name-original name-require req-sym require-depth)))
  
  (define (extract-module-name stx)
    (syntax-case stx ()
      [(module m-name rest ...)
       (and (eq? (syntax-e (syntax module)) 'module)
            (identifier? (syntax m-name)))
       (format "~a" (syntax->datum (syntax m-name)))]
      [else unknown-module-name]))

  ;; maps a path to the path of its "library" (see setup/private/lib-roots)
  (define get-lib-root
    (let ([t (make-hash)]) ; maps paths to their library roots
      (lambda (path)
        (hash-ref! t path (lambda () (path->library-root path))))))

  ;; extract-filenames :
  ;;   (listof (union symbol module-path-index)) string[module-name]
  ;;   -> (listof req)
  (define (extract-filenames direct-requires base)
    (define base-lib (get-lib-root base))
    (for*/list ([dr (in-list direct-requires)]
                [rkt-path (in-value (and (module-path-index? dr)
                                         (resolve-module-path-index dr base)))]
                #:when (path? rkt-path))
      (define path (build-module-filename rkt-path #t))
      (make-req (simplify-path path) (get-key dr base-lib path))))

  (define (get-key dr requiring-libroot required)
    (and (module-path-index? dr)
         ;; files in the same library => return #f as if the require
         ;; is a relative one, so any kind of require from the same
         ;; library is always displayed (regardless of hiding planet
         ;; or lib links)
         (not (equal? requiring-libroot (get-lib-root required)))
         (let-values ([(a b) (module-path-index-split dr)])
           (cond [(symbol? a) 'lib]
                 [(pair? a) (and (symbol? (car a)) (car a))]
                 [else #f])))))

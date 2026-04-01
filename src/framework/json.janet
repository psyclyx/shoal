# json — minimal JSON decoder
#
# Handles the subset needed for tidepool IPC: objects, arrays, strings,
# numbers, booleans, null. No streaming, no encoder.
# Keys can be returned as keywords (keywordize=true).

(defn- skip-ws [s i]
  (var pos i)
  (while (and (< pos (length s))
              (or (= (s pos) (chr " "))
                  (= (s pos) (chr "\t"))
                  (= (s pos) (chr "\n"))
                  (= (s pos) (chr "\r"))))
    (++ pos))
  pos)

(defn- parse-string [s i]
  (var pos (+ i 1)) # skip opening "
  (def buf @"")
  (while (< pos (length s))
    (def ch (s pos))
    (if (= ch (chr "\""))
      (break)
      (if (= ch (chr "\\"))
        (do
          (++ pos)
          (when (< pos (length s))
            (def esc (s pos))
            (cond
              (= esc (chr "\"")) (buffer/push buf "\"")
              (= esc (chr "\\")) (buffer/push buf "\\")
              (= esc (chr "/"))  (buffer/push buf "/")
              (= esc (chr "n"))  (buffer/push buf "\n")
              (= esc (chr "t"))  (buffer/push buf "\t")
              (= esc (chr "r"))  (buffer/push buf "\r")
              (= esc (chr "b"))  (buffer/push buf "\x08")
              (= esc (chr "f"))  (buffer/push buf "\x0C")
              # \u escapes: skip for now, output ?
              (= esc (chr "u"))  (do (+= pos 4) (buffer/push buf "?"))
              (buffer/push buf (string/from-bytes esc)))))
        (buffer/push buf (string/from-bytes ch))))
    (++ pos))
  [(string buf) (+ pos 1)])

(var- json-parse nil)

(defn- parse-array [s i]
  (var pos (skip-ws s (+ i 1)))
  (def arr @[])
  (when (and (< pos (length s)) (= (s pos) (chr "]")))
    (break [arr (+ pos 1)]))
  (while (< pos (length s))
    (def [val npos] (json-parse s pos))
    (array/push arr val)
    (set pos (skip-ws s npos))
    (when (>= pos (length s)) (break))
    (if (= (s pos) (chr ","))
      (set pos (skip-ws s (+ pos 1)))
      (break)))
  (when (and (< pos (length s)) (= (s pos) (chr "]")))
    (++ pos))
  [arr pos])

(defn- parse-object [s i keywordize]
  (var pos (skip-ws s (+ i 1)))
  (def obj @{})
  (when (and (< pos (length s)) (= (s pos) (chr "}")))
    (break [obj (+ pos 1)]))
  (while (< pos (length s))
    # Key
    (def [k kpos] (parse-string s pos))
    (set pos (skip-ws s kpos))
    (when (and (< pos (length s)) (= (s pos) (chr ":")))
      (set pos (skip-ws s (+ pos 1))))
    # Value
    (def [v vpos] (json-parse s pos))
    (put obj (if keywordize (keyword k) k) v)
    (set pos (skip-ws s vpos))
    (when (>= pos (length s)) (break))
    (if (= (s pos) (chr ","))
      (set pos (skip-ws s (+ pos 1)))
      (break)))
  (when (and (< pos (length s)) (= (s pos) (chr "}")))
    (++ pos))
  [obj pos])

(defn- parse-number [s i]
  (var pos i)
  (while (and (< pos (length s))
              (or (<= (chr "0") (s pos) (chr "9"))
                  (= (s pos) (chr "-"))
                  (= (s pos) (chr "+"))
                  (= (s pos) (chr "."))
                  (= (s pos) (chr "e"))
                  (= (s pos) (chr "E"))))
    (++ pos))
  (def numstr (string/slice s i pos))
  [(scan-number numstr) pos])

(var- *keywordize* false)

(varfn json-parse [s i]
  (def pos (skip-ws s i))
  (when (>= pos (length s))
    (break [nil pos]))
  (def ch (s pos))
  (cond
    (= ch (chr "\""))  (parse-string s pos)
    (= ch (chr "{"))   (parse-object s pos *keywordize*)
    (= ch (chr "["))   (parse-array s pos)
    (= ch (chr "t"))   [true (min (+ pos 4) (length s))]   # true
    (= ch (chr "f"))   [false (min (+ pos 5) (length s))]  # false
    (= ch (chr "n"))   [nil (min (+ pos 4) (length s))]    # null
    (or (= ch (chr "-")) (<= (chr "0") ch (chr "9")))
    (parse-number s pos)
    [nil (+ pos 1)]))

(defn json/decode
  "Decode a JSON string. If keywordize is truthy, object keys become keywords."
  [s &opt keywordize]
  (set *keywordize* (truthy? keywordize))
  (def [val _] (json-parse s 0))
  val)

# -- Encoder --

(defn- json-encode-into [buf val]
  (cond
    (nil? val) (buffer/push buf "null")
    (boolean? val) (buffer/push buf (if val "true" "false"))
    (number? val) (buffer/push buf (string/format (if (= val (math/floor val)) "%.0f" "%g") val))
    (or (string? val) (keyword? val) (symbol? val))
    (do
      (buffer/push buf "\"")
      (each ch (string val)
        (case ch
          (chr "\"") (buffer/push buf "\\\"")
          (chr "\\") (buffer/push buf "\\\\")
          (chr "\n") (buffer/push buf "\\n")
          (chr "\r") (buffer/push buf "\\r")
          (chr "\t") (buffer/push buf "\\t")
          (buffer/push buf (string/from-bytes ch))))
      (buffer/push buf "\""))
    (indexed? val)
    (do
      (buffer/push buf "[")
      (for i 0 (length val)
        (when (> i 0) (buffer/push buf ","))
        (json-encode-into buf (val i)))
      (buffer/push buf "]"))
    (dictionary? val)
    (do
      (buffer/push buf "{")
      (var first true)
      (eachp [k v] val
        (if first (set first false) (buffer/push buf ","))
        (json-encode-into buf (string k))
        (buffer/push buf ":")
        (json-encode-into buf v))
      (buffer/push buf "}"))
    (buffer/push buf "null")))

(defn json/encode
  "Encode a Janet value as a JSON string."
  [val]
  (def buf @"")
  (json-encode-into buf val)
  (string buf))

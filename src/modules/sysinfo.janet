# sysinfo — CPU, memory, battery, disk, network, audio data sources
#
# All file I/O uses :async-slurp to avoid blocking the event loop.
# Audio uses pactl subscribe for instant change detection.

(defn- push-history [prev value n]
  "Append value to history array, keeping at most n entries."
  (def h (array/slice (or prev @[])))
  (when (>= (length h) n) (array/remove h 0))
  (array/push h value))

(defn- prefilled [n]
  "Create an array of n zeros for initial sparkline state."
  (array/new-filled n 0))

# -- CPU --

(reg-event-handler :cpu/tick
  (fn [cofx event]
    {:async-slurp {:path "/proc/stat" :event :cpu/read}}))

(reg-event-handler :cpu/read
  (fn [cofx event]
    (def data (get event 1 ""))
    (def line (get (string/split "\n" data) 0))
    (when line
      (def parts (string/split " " line))
      (def vals (seq [p :in (slice parts 1)
                      :when (> (length p) 0)
                      :let [n (scan-number p)]
                      :when n]
                  n))
      (when (>= (length vals) 5)
        (var total 0)
        (each v vals (set total (+ total v)))
        (def idle (+ (get vals 3 0) (get vals 4 0)))
        (def prev (get (cofx :db) :cpu {}))
        (def prev-idle (get prev :prev-idle 0))
        (def prev-total (get prev :prev-total 0))
        (def dt (- total prev-total))
        (def di (- idle prev-idle))
        (def pct (if (> dt 0)
                   (math/round (* 100 (/ (- dt di) dt)))
                   0))
        (def normalized (/ pct 100))
        (def old-pending (get prev :pending))
        (def history (if old-pending
                       (push-history (get prev :history) old-pending 60)
                       (get prev :history (prefilled 60))))
        {:db (put (cofx :db) :cpu {:percent pct
                                    :prev-idle idle
                                    :prev-total total
                                    :history history
                                    :pending normalized})
         :anim {:id :cpu/interp :from 0 :to 1 :duration 2.0 :easing :linear}}))))

(reg-event-handler :init
  (fn [cofx event]
    {:dispatch [:cpu/tick]
     :timer {:delay 2.0 :event [:cpu/tick] :repeat true :id :cpu}}))

(reg-sub :cpu (fn [db] (get db :cpu {})))
(reg-sub :cpu/percent [:cpu] (fn [cpu] (get cpu :percent 0)))
(reg-sub :cpu/history [:cpu] (fn [cpu] (get cpu :history [])))
(reg-sub :cpu/pending [:cpu] (fn [cpu] (get cpu :pending)))
(reg-sub :cpu/text [:cpu]
  (fn [cpu] (string "cpu " (math/floor (get cpu :percent 0)) "%")))

# -- Memory --

(defn- parse-meminfo-value [line]
  "Extract kB value from a /proc/meminfo line like 'MemTotal:    16384 kB'"
  (def parts (string/split " " (get (string/split ":" line) 1 "")))
  (var val 0)
  (each p parts
    (when (> (length p) 0)
      (when-let [n (scan-number p)]
        (set val n)
        (break))))
  val)

(reg-event-handler :mem/tick
  (fn [cofx event]
    {:async-slurp {:path "/proc/meminfo" :event :mem/read}}))

(reg-event-handler :mem/read
  (fn [cofx event]
    (def data (get event 1 ""))
    (when (> (length data) 0)
      (var total-kb 0)
      (var avail-kb 0)
      (each line (string/split "\n" data)
        (cond
          (string/has-prefix? "MemTotal:" line)
          (set total-kb (parse-meminfo-value line))
          (string/has-prefix? "MemAvailable:" line)
          (set avail-kb (parse-meminfo-value line))))
      (when (> total-kb 0)
        (def used-mb (math/floor (/ (- total-kb avail-kb) 1024)))
        (def total-mb (math/floor (/ total-kb 1024)))
        (def pct (math/round (* 100.0 (/ (- total-kb avail-kb) total-kb))))
        (def prev-mem (get (cofx :db) :mem {}))
        (def normalized (/ pct 100))
        (def old-pending (get prev-mem :pending))
        (def history (if old-pending
                       (push-history (get prev-mem :history) old-pending 60)
                       (get prev-mem :history (prefilled 60))))
        {:db (put (cofx :db) :mem {:used-mb used-mb
                                    :total-mb total-mb
                                    :percent pct
                                    :history history
                                    :pending normalized})
         :anim {:id :mem/interp :from 0 :to 1 :duration 5.0 :easing :linear}}))))

(reg-event-handler :init
  (fn [cofx event]
    {:dispatch [:mem/tick]
     :timer {:delay 5.0 :event [:mem/tick] :repeat true :id :mem}}))

(reg-sub :mem (fn [db] (get db :mem {})))
(reg-sub :mem/history [:mem] (fn [mem] (get mem :history [])))
(reg-sub :mem/pending [:mem] (fn [mem] (get mem :pending)))
(defn- fmt-mem [mb]
  (if (>= mb 1024)
    (let [gib (/ mb 1024)
          whole (math/floor gib)
          frac (math/floor (* 10 (- gib whole)))]
      (string whole "." frac "G"))
    (string (math/floor mb) "M")))

(reg-sub :mem/text [:mem]
  (fn [mem]
    (string "mem " (fmt-mem (get mem :used-mb 0))
            "/" (fmt-mem (get mem :total-mb 0)))))

# -- Battery --

(defn- slurp-trim [path]
  "Read a file and trim whitespace. Returns nil on failure."
  (try (string/trim (slurp path)) ([_] nil)))

(defn- find-battery-path []
  (var result nil)
  (try
    (each entry (os/dir "/sys/class/power_supply")
      (def base (string "/sys/class/power_supply/" entry))
      (when (= (slurp-trim (string base "/type")) "Battery")
        (def scope (slurp-trim (string base "/scope")))
        (when (and (not= scope "Device")
                   (slurp-trim (string base "/capacity")))
          (set result base)
          (break))))
    ([_] nil))
  result)

(var- bat-path nil)

(reg-event-handler :bat/tick
  (fn [cofx event]
    (when (nil? bat-path)
      (set bat-path (or (find-battery-path) false)))
    (if bat-path
      (let [cap-str (slurp-trim (string bat-path "/capacity"))]
        (if cap-str
          (let [cap (or (scan-number cap-str) 0)
                status (or (slurp-trim (string bat-path "/status")) "Unknown")
                charging (= status "Charging")]
            {:db (put (cofx :db) :bat {:percent cap
                                        :charging charging
                                        :status status
                                        :present true})})
          {:db (put (cofx :db) :bat {:present false})}))
      {:db (put (cofx :db) :bat {:present false})})))

(reg-event-handler :init
  (fn [cofx event]
    {:dispatch [:bat/tick]
     :timer {:delay 10.0 :event [:bat/tick] :repeat true :id :bat}}))

(reg-sub :bat (fn [db] (get db :bat {})))
(reg-sub :bat/present [:bat] (fn [bat] (get bat :present false)))
(reg-sub :bat/text [:bat]
  (fn [bat]
    (if (bat :present)
      (string "bat " (if (bat :charging) "+" "") (math/floor (get bat :percent 0)) "%")
      nil)))

# -- Disk --

(reg-event-handler :disk/tick
  (fn [cofx event]
    (def info (disk-usage "/"))
    (when info
      (def total (get info :total 0))
      (def used (get info :used 0))
      (def pct (get info :percent 0))
      {:db (put (cofx :db) :disk {:total-gb (/ total 1073741824)
                                   :used-gb (/ used 1073741824)
                                   :percent (math/round pct)})})))

(reg-event-handler :init
  (fn [cofx event]
    {:dispatch [:disk/tick]
     :timer {:delay 30.0 :event [:disk/tick] :repeat true :id :disk}}))

(reg-sub :disk (fn [db] (get db :disk {})))

# -- Network --

(defn- default-iface []
  (def data (try (slurp "/proc/net/route") ([_] nil)))
  (when data
    (var result nil)
    (each line (string/split "\n" data)
      (def parts (string/split "\t" line))
      (when (and (>= (length parts) 2)
                 (= (get parts 1) "00000000"))
        (set result (get parts 0))
        (break)))
    result))

(defn- get-local-ipv4 []
  (def data (try (slurp "/proc/net/fib_trie") ([_] nil)))
  (when data
    (var result nil)
    (each line (string/split "\n" data)
      (def trimmed (string/trim line))
      (when (and (string/has-prefix? "+-- " trimmed)
                 (string/find "/32 host LOCAL" trimmed))
        (def ip (get (string/split "/" (string/slice trimmed 4)) 0))
        (when (and ip (not (string/has-prefix? "127." ip)))
          (set result ip)
          (break))))
    result))

(var- net-iface nil)

(reg-event-handler :net/tick
  (fn [cofx event]
    {:async-slurp {:path "/proc/net/dev" :event :net/read}}))

(reg-event-handler :net/read
  (fn [cofx event]
    (when (nil? net-iface)
      (set net-iface (or (default-iface) "wlan0")))
    (def data (get event 1 ""))
    (var now nil)
    (each line (string/split "\n" data)
      (when (string/find ":" line)
        (def halves (string/split ":" line))
        (def name (string/trim (get halves 0 "")))
        (when (= name net-iface)
          (def parts (seq [p :in (string/split " " (get halves 1 ""))
                           :when (> (length p) 0)] p))
          (when (>= (length parts) 10)
            (set now {:rx (or (scan-number (get parts 0)) 0)
                      :tx (or (scan-number (get parts 8)) 0)})
            (break)))))
    (when now
      (def prev (get (cofx :db) :net {}))
      (def prev-rx (get prev :prev-rx 0))
      (def prev-tx (get prev :prev-tx 0))
      (def dt 2.0)
      (def rx-rate (if (> prev-rx 0) (/ (- (now :rx) prev-rx) dt) 0))
      (def tx-rate (if (> prev-tx 0) (/ (- (now :tx) prev-tx) dt) 0))
      (def tick-count (+ 1 (get prev :tick-count 0)))
      (def update-ips (or (nil? (get prev :ipv4)) (= 0 (% tick-count 30))))
      (def ipv4 (if update-ips (or (get-local-ipv4) "") (get prev :ipv4 "")))
      (def rx-raw (max 0 rx-rate))
      (def tx-raw (max 0 tx-rate))
      # EMA smoothing — reduces visual spikiness (alpha=0.3)
      (def alpha 0.3)
      (def rx-smooth (+ (* alpha rx-raw) (* (- 1 alpha) (get prev :rx-smooth 0))))
      (def tx-smooth (+ (* alpha tx-raw) (* (- 1 alpha) (get prev :tx-smooth 0))))
      # Per-direction peaks for independent mirror scaling.
      # Zoom out ~30%/tick, zoom in ~3%/tick.
      (defn- track-peak [smooth hist prev-peak]
        (var dm smooth)
        (each v (or hist @[]) (set dm (max dm v)))
        (def target (* (max dm 1024) 1.2))
        (if (> target prev-peak)
          (+ (* 0.3 target) (* 0.7 prev-peak))
          (+ (* 0.03 target) (* 0.97 prev-peak))))
      (def rx-peak (track-peak rx-smooth (get prev :rx-history) (get prev :rx-peak 1024)))
      (def tx-peak (track-peak tx-smooth (get prev :tx-history) (get prev :tx-peak 1024)))
      (def rx-pending (get prev :rx-pending))
      (def tx-pending (get prev :tx-pending))
      (def rx-hist (if rx-pending
                     (push-history (get prev :rx-history) rx-pending 60)
                     (get prev :rx-history (prefilled 60))))
      (def tx-hist (if tx-pending
                     (push-history (get prev :tx-history) tx-pending 60)
                     (get prev :tx-history (prefilled 60))))
      {:db (put (cofx :db) :net {:rx-rate rx-raw
                                  :tx-rate tx-raw
                                  :rx-smooth rx-smooth
                                  :tx-smooth tx-smooth
                                  :prev-rx (now :rx)
                                  :prev-tx (now :tx)
                                  :iface net-iface
                                  :ipv4 ipv4
                                  :tick-count tick-count
                                  :rx-peak rx-peak
                                  :tx-peak tx-peak
                                  :rx-pending rx-smooth
                                  :tx-pending tx-smooth
                                  :rx-history rx-hist
                                  :tx-history tx-hist})
       :anim {:id :net/interp :from 0 :to 1 :duration 2.0 :easing :linear}})))

(reg-event-handler :init
  (fn [cofx event]
    {:dispatch [:net/tick]
     :timer {:delay 2.0 :event [:net/tick] :repeat true :id :net}}))

(reg-sub :net (fn [db] (get db :net {})))
(reg-sub :net/rx-history [:net] (fn [net] (get net :rx-history [])))
(reg-sub :net/tx-history [:net] (fn [net] (get net :tx-history [])))

# -- Audio (PipeWire/PulseAudio via wpctl + pactl subscribe) --

(reg-event-handler :audio/query
  (fn [cofx event]
    {:spawn {:cmd ["wpctl" "get-volume" "@DEFAULT_AUDIO_SINK@"]
             :event :audio/read}}))

(reg-event-handler :audio/read
  (fn [cofx event]
    (def line (get event 1 ""))
    (def parts (string/split " " line))
    (when (>= (length parts) 2)
      (def vol (or (scan-number (get parts 1 "0")) 0))
      (def pct (math/round (* vol 100)))
      (def muted (truthy? (string/find "[MUTED]" line)))
      {:db (put (cofx :db) :audio {:percent pct :muted muted})})))

(reg-event-handler :audio/subscribe-event
  (fn [cofx event]
    (def line (get event 1 ""))
    (when (string/find "sink" line)
      {:dispatch [:audio/query]})))

(reg-event-handler :audio/start-subscribe
  (fn [cofx event]
    {:spawn {:cmd ["pactl" "subscribe"]
             :event :audio/subscribe-event
             :done :audio/subscribe-exited}}))

(reg-event-handler :audio/subscribe-exited
  (fn [cofx event]
    {:timer {:delay 2.0 :event [:audio/start-subscribe] :id :audio-resub}}))

(reg-event-handler :init
  (fn [cofx event]
    {:dispatch-n [[:audio/query] [:audio/start-subscribe]]}))

(reg-sub :audio (fn [db] (get db :audio {})))

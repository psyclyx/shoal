# sysinfo — CPU, memory, battery, disk, network, audio data sources
#
# All file I/O uses :async-slurp to avoid blocking the event loop.
# Audio uses pactl subscribe for instant change detection.

# -- CPU --

(def- N-BARS 15)
(def- CPU-SMOOTH 0.3)

(reg-event-handler :cpu/tick
  (fn [cofx event]
    {:async-slurp {:path "/proc/stat" :event :cpu/read}}))

(reg-event-handler :cpu/read
  (fn [cofx event]
    (let [data (get event 1 "")
          line (get (string/split "\n" data) 0)]
      (when line
        (def vals (seq [p :in (slice (string/split " " line) 1)
                        :when (> (length p) 0)
                        :let [n (scan-number p)]
                        :when n]
                    n))
        (when (>= (length vals) 5)
          (var total 0)
          (each v vals (set total (+ total v)))
          (let [idle (+ (get vals 3 0) (get vals 4 0))
                prev (get (cofx :db) :cpu {})
                dt (- total (get prev :prev-total 0))
                di (- idle (get prev :prev-idle 0))
                pct (if (> dt 0)
                      (math/round (* 100 (/ (- dt di) dt)))
                      0)
                normalized (/ pct 100)
                clock (os/clock :monotonic)
                bars (or (get prev :bars) (array/new-filled (+ N-BARS 1) 0))
                smoothed (+ (* CPU-SMOOTH normalized)
                            (* (- 1 CPU-SMOOTH) (or (last bars) 0)))
                new-bars (array/slice bars 1)]
            (array/push new-bars smoothed)
            {:db (put (cofx :db) :cpu {:percent pct
                                        :prev-idle idle
                                        :prev-total total
                                        :bars new-bars
                                        :tick-clock clock})
             :render :default}))))))

(reg-event-handler :init
  (fn [cofx event]
    {:dispatch [:cpu/tick]
     :timer {:delay 2.0 :event [:cpu/tick] :repeat true :id :cpu}
     # Heartbeat animation keeps render loop at 60fps for smooth time-based charts
     :anim {:id :render-heartbeat :to 1 :duration 9999 :easing :linear
            :surface :default}}))

(reg-sub :cpu (fn [db] (get db :cpu {})))
(reg-sub :cpu/percent [:cpu] (fn [cpu] (get cpu :percent 0)))
(reg-sub :cpu/text [:cpu]
  (fn [cpu] (string/format "cpu %d%%" (math/floor (get cpu :percent 0)))))

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
    (let [data (get event 1 "")]
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
          (let [used-mb (math/floor (/ (- total-kb avail-kb) 1024))
                total-mb (math/floor (/ total-kb 1024))
                pct (math/round (* 100.0 (/ (- total-kb avail-kb) total-kb)))]
            {:db (put (cofx :db) :mem {:used-mb used-mb
                                        :total-mb total-mb
                                        :percent pct})
             :render :default}))))))

(reg-event-handler :init
  (fn [cofx event]
    {:dispatch [:mem/tick]
     :timer {:delay 5.0 :event [:mem/tick] :repeat true :id :mem}}))

(reg-sub :mem (fn [db] (get db :mem {})))
(defn- fmt-mem [mb]
  (if (>= mb 1024)
    (let [gib (/ mb 1024)
          whole (math/floor gib)
          frac (math/floor (* 10 (- gib whole)))]
      (string/format "%d.%dG" whole frac))
    (string/format "%dM" (math/floor mb))))

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
                                        :present true})
             :render :default})
          {:db (put (cofx :db) :bat {:present false})
           :render :default}))
      {:db (put (cofx :db) :bat {:present false})
       :render :default})))

(reg-event-handler :init
  (fn [cofx event]
    {:dispatch [:bat/tick]
     :timer {:delay 10.0 :event [:bat/tick] :repeat true :id :bat}}))

(reg-sub :bat (fn [db] (get db :bat {})))
(reg-sub :bat/present [:bat] (fn [bat] (get bat :present false)))
(reg-sub :bat/text [:bat]
  (fn [bat]
    (if (bat :present)
      (string/format "bat %s%d%%" (if (bat :charging) "+" "") (math/floor (get bat :percent 0)))
      nil)))

# -- Disk --

(reg-event-handler :disk/tick
  (fn [cofx event]
    (when-let [info (disk-usage "/")]
      (let [total (get info :total 0)
            used (get info :used 0)
            pct (get info :percent 0)]
          {:db (put (cofx :db) :disk {:total-gb (/ total 1073741824)
                                       :used-gb (/ used 1073741824)
                                       :percent (math/round pct)})
           :render :default}))))

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

(def- NET-SAMPLE-SEC 1.5)
(def- NET-DISPLAY-SEC 30.0)
(def- NET-SPARK-LAG 2.0)
(def- NET-HISTORY-SEC 45.0)
(def- NET-ZOOM-HOLD-SEC (+ NET-SPARK-LAG (/ NET-DISPLAY-SEC 2)))
(def- NET-SMOOTH-TAU 3.0)
(def- NET-ZOOM-FLOOR 131072.0) # 128 KiB/s full-scale minimum
(def- NET-ZOOM-HEADROOM-LINE 0.78)
(def- NET-ZOOM-RECENT-TAU 8.0)
(def- NET-ZOOM-OLD-WEIGHT 0.18)
(def- NET-ZOOM-UP-TAU 0.8)
(def- NET-ZOOM-DOWN-TAU 6.0)

(defn- exp-decay [dt tau]
  (if (<= tau 0) 1.0
    (- 1.0 (math/exp (- (/ (max 0 dt) tau))))))

(defn- smooth-rate [prev raw dt]
  (let [a (exp-decay dt NET-SMOOTH-TAU)]
    (+ (* a raw) (* (- 1 a) prev))))

(defn- prune-timed [items cutoff key]
  (def out @[])
  (each item items
    (when (>= (get item key 0) cutoff)
      (array/push out item)))
  out)

(defn- secant [a b key]
  (let [dt (max 0.001 (- (b :t) (a :t)))]
    (/ (- (b key) (a key)) dt)))

(defn- monotone-slope [d0 d1 h0 h1]
  (if (or (= d0 0) (= d1 0) (<= (* d0 d1) 0))
    0.0
    (let [w1 (+ (* 2 h1) h0)
          w2 (+ h1 (* 2 h0))]
      (/ (+ w1 w2)
         (+ (/ w1 d0) (/ w2 d1))))))

(defn- clamp-hermite-slopes [d m0 m1]
  (if (= d 0)
    [0.0 0.0]
    (let [a (/ m0 d)
          b (/ m1 d)
          mag (+ (* a a) (* b b))]
      (if (> mag 9)
        (let [scale (/ 3.0 (math/sqrt mag))]
          [(* scale a d) (* scale b d)])
        [m0 m1]))))

(defn- cubic-coeffs [y0 y1 m0 m1 h]
  [ (+ (* 2 (- y0 y1)) (* h (+ m0 m1)))
    (- (* 3 (- y1 y0)) (* h (+ (* 2 m0) m1)))
    (* h m0)
    y0])

(defn- interval-coeffs [samples idx key]
  (let [a (samples idx)
        b (samples (+ idx 1))
        h (max 0.001 (- (b :t) (a :t)))
        d (secant a b key)
        m0 (if (> idx 0)
             (let [p (samples (- idx 1))
                   hp (max 0.001 (- (a :t) (p :t)))
                   dp (secant p a key)]
               (monotone-slope dp d hp h))
             d)
        slopes (clamp-hermite-slopes d m0 d)]
    (cubic-coeffs (a key) (b key) (slopes 0) (slopes 1) h)))

(defn- finalized-net-interval [samples idx]
  (let [a (samples idx)
        b (samples (+ idx 1))]
    {:t0 (a :t)
     :t1 (b :t)
     :dt (max 0.001 (- (b :t) (a :t)))
     :rx (interval-coeffs samples idx :rx)
     :tx (interval-coeffs samples idx :tx)}))

(defn- net-zoom-at [net now]
  (let [from (get net :zoom-from NET-ZOOM-FLOOR)
        to (get net :zoom-to NET-ZOOM-FLOOR)
        clock (get net :zoom-clock now)
        tau (get net :zoom-tau 0)]
    (if (<= tau 0)
      to
      (+ to (* (- from to)
               (math/exp (- (/ (max 0 (- now clock)) tau))))))))

(defn- target-net-zoom [samples now]
  (var peak 0.0)
  (each s samples
    (let [age (max 0 (- now (s :t)))]
      (when (<= age NET-HISTORY-SEC)
        (let [decay-age (max 0 (- age NET-ZOOM-HOLD-SEC))
              recent (if (<= age NET-ZOOM-HOLD-SEC)
                       1.0
                       (+ NET-ZOOM-OLD-WEIGHT
                          (* (- 1 NET-ZOOM-OLD-WEIGHT)
                             (math/exp (- (/ decay-age NET-ZOOM-RECENT-TAU))))))
              rate (max (s :rx) (s :tx))]
          (set peak (max peak (* rate recent)))))))
  (max NET-ZOOM-FLOOR (/ peak NET-ZOOM-HEADROOM-LINE)))

(defn- eval-cubic [coeff u]
  (+ (* (+ (* (+ (* (coeff 0) u) (coeff 1)) u) (coeff 2)) u)
     (coeff 3)))

(defn- sharpen-interval-u [u]
  # Bias the frozen cubic toward its right endpoint so transitions read
  # crisper without recomputing old intervals.
  (* u u))

(defn- sample-net-intervals [intervals t key]
  (var result nil)
  (each interval intervals
    (when (and (>= t (interval :t0)) (<= t (interval :t1)))
      (let [u (max 0 (min 1 (/ (- t (interval :t0)) (interval :dt))))
            su (sharpen-interval-u u)]
        (set result (max 0 (eval-cubic (interval key) su))))
      (break)))
  (or result 0.0))

(defn net-spark-values
  "Return normalized rx/tx values sampled from frozen cubic network intervals."
  [net count &opt opts]
  (let [now (os/clock :monotonic)
        zoom (max NET-ZOOM-FLOOR (net-zoom-at net now))
        intervals (get net :intervals @[])
        head-time (- now NET-SPARK-LAG)
        bar-w (get opts :bar-width 4)
        bar-gap (get opts :gap 2)
        pitch (+ bar-w bar-gap)
        span (+ (* count bar-w) (* (max 0 (- count 1)) bar-gap))
        rx-values @[]
        tx-values @[]]
    (for i 0 count
      (let [mid-x (+ (* i pitch) (/ bar-w 2))
            # Newest data is at the rightmost bar midpoint. Gaps count as
            # time distance, so wider spacing moves neighboring samples apart.
            age (* NET-DISPLAY-SEC (- 1 (/ mid-x span)))
            t (- head-time age)]
        (array/push rx-values (/ (sample-net-intervals intervals t :rx) zoom))
        (array/push tx-values (/ (sample-net-intervals intervals t :tx) zoom))))
    {:rx rx-values :tx tx-values :zoom zoom}))

(defn- get-link-speed [iface]
  "Get link speed in bytes/sec from sysfs. Returns nil on failure."
  (try
    (do
      (def mbps (scan-number (string/trim (slurp (string "/sys/class/net/" iface "/speed")))))
      (when (and mbps (> mbps 0))
        (* mbps 125000)))
    ([_] nil)))

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
      (let [prev (get (cofx :db) :net {})
            prev-rx (get prev :prev-rx 0)
            prev-tx (get prev :prev-tx 0)
            clock (os/clock :monotonic)
            prev-clock (get prev :prev-clock 0)
            dt (if (> prev-clock 0) (max 0.1 (- clock prev-clock)) 1.0)
            rx-rate (if (> prev-rx 0) (max 0 (/ (- (now :rx) prev-rx) dt)) 0)
            tx-rate (if (> prev-tx 0) (max 0 (/ (- (now :tx) prev-tx) dt)) 0)
            tick-count (+ 1 (get prev :tick-count 0))
            update-ips (or (nil? (get prev :ipv4)) (= 0 (% tick-count 15)))
            ipv4 (if update-ips (or (get-local-ipv4) "") (get prev :ipv4 ""))
            link-speed (or (get prev :link-speed)
                           (get-link-speed net-iface))
            old-samples (get prev :samples @[])
            old-intervals (get prev :intervals @[])
            last-sample (last old-samples)
            sm-rx (if last-sample
                    (smooth-rate (last-sample :rx) rx-rate dt)
                    rx-rate)
            sm-tx (if last-sample
                    (smooth-rate (last-sample :tx) tx-rate dt)
                    tx-rate)
            sample {:t clock :dt dt :rx sm-rx :tx sm-tx}
            samples (array/slice old-samples 0)
            intervals (array/slice old-intervals 0)]
        (array/push samples sample)
        (when (>= (length samples) 2)
          (array/push intervals (finalized-net-interval samples (- (length samples) 2))))
        (let [cutoff (- clock NET-HISTORY-SEC)
              samples (prune-timed samples cutoff :t)
              intervals (prune-timed intervals cutoff :t1)
              current-zoom (net-zoom-at prev clock)
              zoom-target (target-net-zoom samples clock)
              zoom-tau (if (> zoom-target current-zoom)
                         NET-ZOOM-UP-TAU
                         NET-ZOOM-DOWN-TAU)]
        {:db (put (cofx :db) :net {:rx-rate rx-rate
                                    :tx-rate tx-rate
                                    :prev-rx (now :rx)
                                    :prev-tx (now :tx)
                                    :prev-clock clock
                                    :tick-clock clock
                                    :iface net-iface
                                    :ipv4 ipv4
                                    :tick-count tick-count
                                    :link-speed link-speed
                                    :samples samples
                                    :intervals intervals
                                    :zoom-from current-zoom
                                    :zoom-to zoom-target
                                    :zoom-clock clock
                                    :zoom-tau zoom-tau})
         :render :default})))))

(reg-event-handler :init
  (fn [cofx event]
    {:dispatch [:net/tick]
     :timer {:delay NET-SAMPLE-SEC :event [:net/tick] :repeat true :id :net}}))

(reg-sub :net (fn [db] (get db :net {})))

# -- Audio (PipeWire/PulseAudio via wpctl + pactl subscribe) --

(reg-event-handler :audio/query
  (fn [cofx event]
    {:spawn {:cmd ["wpctl" "get-volume" "@DEFAULT_AUDIO_SINK@"]
             :event :audio/read}}))

(reg-event-handler :audio/read
  (fn [cofx event]
    (let [line (get event 1 "")
          parts (string/split " " line)]
      (when (>= (length parts) 2)
        (let [vol (or (scan-number (get parts 1 "0")) 0)
              pct (math/round (* vol 100))
              muted (truthy? (string/find "[MUTED]" line))]
          {:db (put (cofx :db) :audio {:percent pct :muted muted})
           :render :default})))))

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

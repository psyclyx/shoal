# sysinfo — CPU, memory, battery data sources
#
# Uses :timer + slurp to read /proc and /sys. Pure Janet.
# CPU polls every 2s, memory every 5s, battery every 10s.

# -- CPU --

(var- cpu-prev-idle 0)
(var- cpu-prev-total 0)

(reg-event-handler :cpu/tick
  (fn [cofx event]
    (def line
      (try
        (let [data (slurp "/proc/stat")]
          (get (string/split "\n" data) 0))
        ([_] nil)))
    (when line
      (def parts (string/split " " line))
      # /proc/stat "cpu" line: user nice system idle iowait irq softirq steal
      # Filter empty strings from double-space after "cpu"
      (def vals (seq [p :in (slice parts 1)
                      :when (> (length p) 0)]
                  (scan-number p)))
      (when (>= (length vals) 5)
        (var total 0)
        (each v vals (set total (+ total v)))
        (def idle (+ (get vals 3 0) (get vals 4 0)))
        (def dt (- total cpu-prev-total))
        (def di (- idle cpu-prev-idle))
        (def pct (if (> dt 0)
                   (math/round (* 100 (/ (- dt di) dt)))
                   0))
        (set cpu-prev-idle idle)
        (set cpu-prev-total total)
        {:db (put (cofx :db) :cpu {:percent (math/floor pct)})}))))

(reg-event-handler :cpu/start
  (fn [cofx event]
    {:dispatch [:cpu/tick]
     :timer {:delay 2.0 :event [:cpu/tick] :repeat true :id :cpu}}))

(reg-sub :cpu (fn [db] (get db :cpu {})))
(reg-sub :cpu/percent [:cpu] (fn [cpu] (get cpu :percent 0)))
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
    (def data
      (try (slurp "/proc/meminfo") ([_] nil)))
    (when data
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
        {:db (put (cofx :db) :mem {:used-mb used-mb
                                    :total-mb total-mb
                                    :percent (math/floor (* 100 (/ (- total-kb avail-kb) total-kb)))})}))))

(reg-event-handler :mem/start
  (fn [cofx event]
    {:dispatch [:mem/tick]
     :timer {:delay 5.0 :event [:mem/tick] :repeat true :id :mem}}))

(reg-sub :mem (fn [db] (get db :mem {})))
(reg-sub :mem/text [:mem]
  (fn [mem]
    (string "mem " (math/floor (get mem :used-mb 0))
            "/" (math/floor (get mem :total-mb 0)) "M")))

# -- Battery --

(defn- slurp-trim [path]
  "Read a file and trim whitespace. Returns nil on failure."
  (try
    (string/trim (slurp path))
    ([_] nil)))

(reg-event-handler :bat/tick
  (fn [cofx event]
    (def cap-str (slurp-trim "/sys/class/power_supply/BAT0/capacity"))
    (if cap-str
      (let [cap (or (scan-number cap-str) 0)
            status (or (slurp-trim "/sys/class/power_supply/BAT0/status") "Unknown")
            charging (= status "Charging")]
        {:db (put (cofx :db) :bat {:percent cap
                                    :charging charging
                                    :status status
                                    :present true})})
      {:db (put (cofx :db) :bat {:present false})})))

(reg-event-handler :bat/start
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

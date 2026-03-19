# osd — on-screen display for volume and brightness
#
# Shows a transient overlay with a progress bar when volume or brightness
# changes. Triggered by tidepool signals:
#   volume-up, volume-down, volume-mute
#   brightness-up, brightness-down
#
# Adjusts levels via exec (pactl/brightnessctl) and reads them back
# to display the current value.

# --- Helpers ---

(defn- find-backlight-path []
  "Discover backlight sysfs path."
  (var result nil)
  (try
    (each entry (os/dir "/sys/class/backlight")
      (def max-path (string "/sys/class/backlight/" entry "/max_brightness"))
      (when (try (slurp max-path) ([_] nil))
        (set result (string "/sys/class/backlight/" entry))
        (break)))
    ([_] nil))
  result)

(var- backlight-path nil)

(defn- read-brightness []
  "Read current brightness as percentage (0-100)."
  (when (nil? backlight-path)
    (set backlight-path (or (find-backlight-path) false)))
  (when backlight-path
    (def cur (try (scan-number (string/trim (slurp (string backlight-path "/brightness"))))
               ([_] nil)))
    (def mx (try (scan-number (string/trim (slurp (string backlight-path "/max_brightness"))))
              ([_] nil)))
    (when (and cur mx (> mx 0))
      (math/round (* 100 (/ cur mx))))))

# --- Subscriptions ---

(reg-sub :osd/visible?
  (fn [db] (get db :osd/visible? false)))

(reg-sub :osd/value
  (fn [db] (get db :osd/value 0)))

(reg-sub :osd/label
  (fn [db] (get db :osd/label "")))

(reg-sub :osd/muted?
  (fn [db] (get db :osd/muted? false)))

# --- View ---

(def- bg (theme :bg))
(def- surface-color (theme :surface))
(def- overlay-color (theme :overlay))
(def- text-color (theme :text))
(def- bright (theme :bright))
(def- muted-color (theme :muted))
(def- subtle (theme :subtle))
(def- accent (theme :accent))
(def- green (theme :base0B))
(def- red (theme :base08))
(def- yellow (theme :base0A))

(defn osd-view []
  (def value (sub :osd/value))
  (def label (sub :osd/label))
  (def is-muted (sub :osd/muted?))
  (def reveal (anim :osd/reveal))
  (def alpha (math/floor (* reveal 255)))

  (def bar-w 220)
  (def fill-w (math/floor (* bar-w (/ (min value 100) 100))))
  (def bar-color (cond
                   is-muted red
                   (>= value 100) yellow
                   accent))

  [:col {:w :grow :h :grow :align-x :center :align-y :center}
    [:col {:w 280 :bg [(bg 0) (bg 1) (bg 2) alpha]
           :radius 12 :pad 16 :gap 10 :align-x :center}
      # Label
      [:text {:color [(text-color 0) (text-color 1) (text-color 2) alpha] :size 14}
        label]
      # Progress bar
      [:row {:w bar-w :h 8 :bg [(surface-color 0) (surface-color 1) (surface-color 2) alpha]
             :radius 4}
        [:row {:w fill-w :h 8
               :bg [(bar-color 0) (bar-color 1) (bar-color 2) alpha]
               :radius 4}]]
      # Percentage
      [:text {:color [(bright 0) (bright 1) (bright 2) alpha] :size 22}
        (string (math/floor value) (if is-muted " (muted)" "%"))]]])

(reg-view :osd osd-view)

# --- Event Handlers ---

(defn- osd/show [db label value &opt muted]
  "Update db and return fx to show the OSD."
  (def updated (-> db
                   (put :osd/visible? true)
                   (put :osd/label label)
                   (put :osd/value value)
                   (put :osd/muted? (truthy? muted))))
  (def effects @{:db updated
                 :anim {:id :osd/reveal :to 1 :duration 0.12 :easing :ease-out-cubic}
                 :timer {:delay 1.5 :event [:osd/hide] :id :osd-timeout}})
  (when (not (get db :osd/visible?))
    (put effects :surface
      {:create {:name :osd
                :layer :overlay
                :width 320
                :height 120
                :anchor {:top true}
                :margin {:top 80}
                :keyboard-interactivity :none}}))
  effects)

(reg-event-handler :osd/hide
  (fn [cofx event]
    {:anim {:id :osd/reveal :to 0 :duration 0.2 :easing :ease-in-out-quad
            :on-complete [:osd/destroy]}}))

(reg-event-handler :osd/destroy
  (fn [cofx event]
    {:db (put (cofx :db) :osd/visible? false)
     :surface {:destroy :osd}}))

# --- Volume ---

(reg-event-handler :osd/volume-up
  (fn [cofx event]
    {:exec {:cmd "pactl set-sink-volume @DEFAULT_SINK@ +5%"}
     :timer {:delay 0.05 :event [:osd/volume-query] :id :osd-vol-read}}))

(reg-event-handler :osd/volume-down
  (fn [cofx event]
    {:exec {:cmd "pactl set-sink-volume @DEFAULT_SINK@ -5%"}
     :timer {:delay 0.05 :event [:osd/volume-query] :id :osd-vol-read}}))

(reg-event-handler :osd/volume-mute
  (fn [cofx event]
    {:exec {:cmd "pactl set-sink-mute @DEFAULT_SINK@ toggle"}
     :timer {:delay 0.05 :event [:osd/volume-query] :id :osd-vol-read}}))

(reg-event-handler :osd/volume-query
  (fn [cofx event]
    {:spawn {:cmd ["wpctl" "get-volume" "@DEFAULT_AUDIO_SINK@"]
             :event :osd/volume-read}}))

(reg-event-handler :osd/volume-read
  (fn [cofx event]
    # wpctl output: "Volume: 0.50" or "Volume: 0.50 [MUTED]"
    (def line (get event 1 ""))
    (def parts (string/split " " line))
    (when (>= (length parts) 2)
      (def vol-str (get parts 1 "0"))
      (def vol (or (scan-number vol-str) 0))
      (def pct (math/round (* vol 100)))
      (def muted (truthy? (string/find "[MUTED]" line)))
      # Update both OSD and bar audio state
      (def db (put (cofx :db) :audio {:percent pct :muted muted}))
      (osd/show db "Volume" pct muted))))

# --- Brightness ---

(reg-event-handler :osd/brightness-up
  (fn [cofx event]
    {:exec {:cmd "brightnessctl set +10%"}
     :timer {:delay 0.05 :event [:osd/brightness-read] :id :osd-br-read}}))

(reg-event-handler :osd/brightness-down
  (fn [cofx event]
    {:exec {:cmd "brightnessctl set 10%-"}
     :timer {:delay 0.05 :event [:osd/brightness-read] :id :osd-br-read}}))

(reg-event-handler :osd/brightness-read
  (fn [cofx event]
    (def pct (read-brightness))
    (when pct
      (osd/show (cofx :db) "Brightness" pct))))

# --- Signal integration ---

(reg-event-handler :tp/signal
  (fn [cofx event]
    (def name (get event 1 ""))
    (case name
      "volume-up"        {:dispatch [:osd/volume-up]}
      "volume-down"      {:dispatch [:osd/volume-down]}
      "volume-mute"      {:dispatch [:osd/volume-mute]}
      "brightness-up"    {:dispatch [:osd/brightness-up]}
      "brightness-down"  {:dispatch [:osd/brightness-down]})))

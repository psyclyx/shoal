# osd — on-screen display for volume and brightness
#
# Reactive OSD: watches audio state from sysinfo.janet and shows a
# transient overlay when volume or mute state changes. Does not
# adjust levels — that's the compositor's or DE's job.

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
(def- text-color (theme :text))
(def- bright (theme :bright))
(def- accent (theme :accent))
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
      [:text {:color [(text-color 0) (text-color 1) (text-color 2) alpha] :size 14}
        label]
      [:row {:w bar-w :h 8 :bg [(surface-color 0) (surface-color 1) (surface-color 2) alpha]
             :radius 4}
        [:row {:w fill-w :h 8
               :bg [(bar-color 0) (bar-color 1) (bar-color 2) alpha]
               :radius 4}]]
      [:text {:color [(bright 0) (bright 1) (bright 2) alpha] :size 22}
        (string (math/floor value) (if is-muted " (muted)" "%"))]]])

(reg-view :osd osd-view)

# --- Show / Hide ---

(defn- osd/show [db label value &opt muted]
  "Update db and return fx to show the OSD."
  (def was-visible (get db :osd/visible? false))
  (def updated (-> db
                   (put :osd/visible? true)
                   (put :osd/label label)
                   (put :osd/value value)
                   (put :osd/muted? (truthy? muted))))
  (def effects @{:db updated
                 :anim {:id :osd/reveal :to 1 :duration 0.12 :easing :ease-out-cubic}
                 :timer {:delay 1.5 :event [:osd/hide] :id :osd-timeout}})
  (when (not was-visible)
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

# --- Reactive volume watcher ---
# Compares current audio state to previous snapshot each time sysinfo
# updates. Shows OSD when volume or mute state changes.

(reg-event-handler :audio/read
  (fn [cofx event]
    (def db (cofx :db))
    (def audio (get db :audio {}))
    (def prev (get db :osd/prev-audio {}))
    (def pct (get audio :percent 0))
    (def muted (get audio :muted false))
    (def prev-pct (get prev :percent 0))
    (def prev-muted (get prev :muted false))
    # Only show OSD after the first read (prev exists) and something changed
    (if (and (not (empty? prev))
             (or (not= pct prev-pct) (not= muted prev-muted)))
      (osd/show (put db :osd/prev-audio audio) "Volume" pct muted)
      {:db (put db :osd/prev-audio audio)})))

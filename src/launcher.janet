# launcher — Universal Seam
#
# One surface, one interaction, every "choose and act" moment.
# Creates a transient overlay surface with keyboard interactivity.
#
# Prefix-based modes:
#   (none) — all items (apps + windows + tags)
#   @      — windows only
#   #      — tags only
#   !      — apps only
#   >      — tidepool actions
#   :      — tidepool command (dispatched directly)
#   =      — eval Janet on tidepool REPL

# --- Helpers ---

(defn- fuzzy-score [query label]
  "Fuzzy match with scoring. Returns score (higher = better) or nil if no match.
  Bonuses: consecutive chars, word boundary hits, prefix match."
  (when (and query label (> (length query) 0) (> (length label) 0))
    (def q (string/ascii-lower query))
    (def l (string/ascii-lower label))
    (def qlen (length q))
    (def llen (length l))
    (var qi 0)
    (var score 0)
    (var prev-match -2) # position of previous matched char
    (for li 0 llen
      (when (and (< qi qlen) (= (get q qi) (get l li)))
        # Consecutive match bonus
        (if (= (- li 1) prev-match)
          (+= score 4)
          (+= score 1))
        # Word boundary bonus (start, after space/dash/underscore)
        (when (or (= li 0)
                  (let [prev-ch (get l (- li 1))]
                    (or (= prev-ch (chr " "))
                        (= prev-ch (chr "-"))
                        (= prev-ch (chr "_"))
                        (= prev-ch (chr "/")))))
          (+= score 3))
        # Prefix bonus
        (when (= qi li) (+= score 2))
        (set prev-match li)
        (++ qi)))
    (when (= qi qlen) score)))

(defn- filter-items [items query]
  (if (or (nil? query) (= query ""))
    items
    (let [scored (seq [item :in items
                       :let [s (fuzzy-score query (item :label))]
                       :when s]
                   {:item item :score s})]
      (sort scored |(> ($0 :score) ($1 :score)))
      (map |($ :item) scored))))

(defn- clamp [v lo hi]
  (min hi (max lo v)))

(defn- parse-mode [query]
  "Parse prefix from query. Returns [mode stripped-query]."
  (cond
    (string/has-prefix? "@" query) [:window (string/slice query 1)]
    (string/has-prefix? "#" query) [:tag (string/slice query 1)]
    (string/has-prefix? "!" query) [:app (string/slice query 1)]
    (string/has-prefix? ">" query) [:action (string/slice query 1)]
    (string/has-prefix? ":" query) [:command (string/slice query 1)]
    (string/has-prefix? "=" query) [:eval (string/slice query 1)]
    [:all query]))

(defn- build-live-items [db mode]
  "Build only the live (non-cached) items: windows + tags."
  (def tp (get db :tp {}))
  (def items @[])
  (when (or (= mode :all) (= mode :window))
    (each w (get tp :windows [])
      (def title (get w :title ""))
      (def app-id (get w :app-id ""))
      (def label (if (and (> (length app-id) 0) (not= app-id title))
                   (string title " — " app-id)
                   title))
      (when (> (length label) 0)
        (array/push items {:label label
                           :kind :window
                           :wid (get w :wid 0)
                           :tag (get w :tag 0)
                           :focused (get w :focused false)}))))
  (when (or (= mode :all) (= mode :tag))
    (def tags (get tp :tags []))
    (for i 1 10
      (def tag (get tags i))
      (def occupied (and tag (get tag :occupied false)))
      (def focused (and tag (get tag :focused false)))
      (array/push items {:label (string (if focused "● " (if occupied "○ " "  "))
                                        "Tag " i)
                         :kind :tag
                         :tag-num i})))
  items)

(defn- build-items [db mode]
  "Build complete item list: pre-built cached items + live items."
  (def items @[])
  (when (= mode :action)
    (array/concat items (get db :launcher/action-items [])))
  (when (or (= mode :all) (= mode :app))
    (array/concat items (get db :launcher/app-items [])))
  (array/concat items (build-live-items db mode))
  items)

(defn- launcher/update-results [db]
  "Filter items by current query and store results in db."
  (def items (get db :launcher/items []))
  (def query (get db :launcher/query ""))
  (def [_ stripped] (parse-mode query))
  (put db :launcher/results (filter-items items stripped)))

# --- Caching: scan apps and query actions on startup + timer + close ---

(defn- launcher/build-app-items [apps]
  "Pre-build app item structs from raw desktop app data."
  (map |(do {:label ($ :name) :kind :app :exec ($ :exec)}) apps))

(defn- launcher/build-action-items [actions]
  "Pre-build action item structs from raw action data."
  (map |(do
    (def key (get $ :key ""))
    (def label (string ($ :name)
                       (when (> (length key) 0) (string "  [" key "]"))
                       (when (get $ :desc)
                         (string " — " ($ :desc)))))
    {:label label :kind :action :action-name ($ :name)}) actions))

(defn- launcher/cache-apps [db]
  "Scan desktop apps and store deduplicated sorted list + pre-built items in db."
  (def apps (desktop-apps))
  (def seen @{})
  (def unique-apps @[])
  (each app apps
    (def n (get app :name ""))
    (when (and (> (length n) 0) (not (get seen n)))
      (put seen n true)
      (array/push unique-apps app)))
  (sort unique-apps |(< (get $0 :name "") (get $1 :name "")))
  (-> db
      (put :launcher/apps unique-apps)
      (put :launcher/app-items (launcher/build-app-items unique-apps))))

(reg-event-handler :init
  (fn [cofx event]
    {:db (launcher/cache-apps (cofx :db))
     :timer {:delay 60 :event [:launcher/refresh] :repeat true :id :launcher-refresh}}))

(reg-event-handler :launcher/refresh
  (fn [cofx event]
    {:db (launcher/cache-apps (cofx :db))
     :dispatch [:launcher/query-actions]}))

(reg-event-handler :launcher/query-actions
  (fn [cofx event]
    (when (get-in (cofx :db) [:tp :connected])
      {:ipc {:send {:name :tp-cmd
                     :data "(ipc/list-actions)\n"}}})))

# When tp-cmd connects, query actions immediately
(reg-event-handler :tp-cmd/connected
  (fn [cofx event]
    {:dispatch [:launcher/query-actions]}))

# Handle tp-cmd responses — detect action list by shape
(reg-event-handler :tp-cmd/recv
  (fn [cofx event]
    (def msg-type (get event 1))
    (def payload (get event 2))
    (when (= msg-type :return)
      (try
        (do
          (def data (json/decode payload true))
          (when (and data (indexed? data)
                     (> (length data) 0)
                     (get (first data) :name))
            {:db (-> (cofx :db)
                     (put :launcher/actions data)
                     (put :launcher/action-items (launcher/build-action-items data)))}))
        ([err] nil)))))

# --- Subscriptions ---

(reg-sub :launcher/open?
  (fn [db] (get db :launcher/open? false)))

(reg-sub :launcher/query
  (fn [db] (get db :launcher/query "")))

(reg-sub :launcher/selected
  (fn [db] (get db :launcher/selected 0)))

(reg-sub :launcher/results
  (fn [db] (get db :launcher/results [])))

# --- View ---

(def- bg (theme :bg))
(def- surface-color (theme :surface))
(def- overlay-color (theme :overlay))
(def- text-color (theme :text))
(def- bright (theme :bright))
(def- muted (theme :muted))
(def- subtle (theme :subtle))
(def- accent (theme :accent))

(defn- result-item [idx item selected]
  (def active (= idx selected))
  (def kind-color (case (item :kind)
                    :app (theme :base0B)
                    :action (theme :base0E)
                    :window accent
                    :tag muted
                    subtle))
  [:row {:id (string "result-" idx) :w :grow :h 32
         :bg (if active (theme :base02) surface-color)
         :radius 4 :pad [4 12] :align-y :center :gap 8}
    [:row {:w 4 :h 16 :bg (if active kind-color [0 0 0 0]) :radius 2}]
    [:text {:color (if active bright text-color) :size 14}
      (item :label)]])

(defn launcher-view []
  (def query (sub :launcher/query))
  (def results (sub :launcher/results))
  (def selected (sub :launcher/selected))
  (def reveal (anim :launcher/reveal))
  (def max-visible 10)
  (def total (length results))

  # Scroll offset: keep selected item visible
  (def scroll-off (max 0 (min (- selected (- max-visible 1))
                               (- total max-visible))))
  (def visible-end (min total (+ scroll-off max-visible)))

  (def alpha (math/floor (* reveal 255)))
  (def launcher-bg surface-color)
  (def input-bg overlay-color)

  [:col {:w :grow :h :grow :bg [(launcher-bg 0) (launcher-bg 1) (launcher-bg 2) alpha]
         :radius 8 :pad 12}
    # Input field
    [:row {:h 40 :w :grow :bg [(input-bg 0) (input-bg 1) (input-bg 2) alpha]
           :radius 6 :pad [8 12] :align-y :center}
      [:text {:color bright :size 16}
        (string query "│")]]
    # Results list
    [:col {:w :grow :gap 2 :pad [8 0 0 0]}
      ;(seq [i :range [scroll-off visible-end]
             :let [item (results i)]]
         (result-item i item selected))]
    # Footer hint
    (def [mode _] (parse-mode query))
    [:row {:h 20 :w :grow :align-x :center :align-y :center}
      [:text {:color subtle :size 11}
        (case mode
          :command "Enter to dispatch action · Esc to cancel"
          :eval "Enter to evaluate · Esc to cancel"
          (string (length results) " result"
                  (if (not= (length results) 1) "s" "")
                  " · !apps @windows #tags >actions :cmd =eval"))]]])

(reg-view :launcher launcher-view)

# --- Event Handlers ---

(reg-event-handler :launcher/open
  (fn [cofx event]
    (def db (cofx :db))
    (def initial-query (or (get event 1) ""))
    (def [init-mode _] (parse-mode initial-query))
    (def items (build-items db init-mode))
    {:db (-> db
             (put :launcher/open? true)
             (put :launcher/query initial-query)
             (put :launcher/selected 0)
             (put :launcher/items items)
             (launcher/update-results))
     :surface {:create {:name :launcher
                        :layer :overlay
                        :width 600
                        :height 460
                        :anchor {:top true}
                        :margin {:top 200}
                        :keyboard-interactivity :exclusive}}
     :anim {:id :launcher/reveal :to 1 :duration 0.15 :easing :ease-out-cubic}}))

(reg-event-handler :launcher/close
  (fn [cofx event]
    {:db (-> (cofx :db)
             (put :launcher/open? false)
             (put :launcher/query "")
             (put :launcher/items [])
             (put :launcher/selected 0))
     :anim {:id :launcher/reveal :to 0 :duration 0.12 :easing :ease-in-out-quad
            :on-complete [:launcher/destroy]}
     :dispatch [:launcher/refresh]}))

(reg-event-handler :launcher/destroy
  (fn [cofx event]
    {:surface {:destroy :launcher}}))


(reg-event-handler :launcher/select
  (fn [cofx event]
    (def db (cofx :db))
    (def results (get db :launcher/results []))
    (def selected (get db :launcher/selected 0))
    (def query (get db :launcher/query ""))
    (def [mode stripped] (parse-mode query))

    (case mode
      # Direct command: dispatch action by name
      :command
      (when (> (length stripped) 0)
        {:dispatch-n [[:tp/dispatch-action stripped] [:launcher/close]]})

      # Eval: send arbitrary Janet to tidepool REPL
      :eval
      (when (> (length stripped) 0)
        {:ipc {:send {:name :tp-cmd :data (string stripped "\n")}}
         :dispatch [:launcher/close]})

      # Normal item selection
      (when (and (> (length results) 0) (<= selected (- (length results) 1)))
        (def item (results selected))
        (case (item :kind)
          :app    {:exec {:cmd (item :exec)} :dispatch [:launcher/close]}
          :action {:dispatch-n [[:tp/dispatch-action (item :action-name)] [:launcher/close]]}
          :window {:dispatch-n [[:tp/focus-window (item :wid)] [:launcher/close]]}
          :tag    {:dispatch-n [[:tp/focus-tag (item :tag-num)] [:launcher/close]]}
          {:dispatch [:launcher/close]})))))

# Focus a window by wid — send to tidepool
(reg-event-handler :tp/focus-window
  (fn [cofx event]
    (def wid (get event 1 0))
    {:ipc {:send {:name :tp-cmd
                  :data (string "(ipc/dispatch \"focus-window\" " wid ")\n")}}}))

# --- Keyboard handling (only when launcher is open) ---

(defn- launcher/set-query [db new-query]
  "Update query, rebuild items if mode changed, re-filter, clamp selection."
  (def old-query (get db :launcher/query ""))
  (def [old-mode _] (parse-mode old-query))
  (def [new-mode new-stripped] (parse-mode new-query))
  (def db2 (put db :launcher/query new-query))
  # Rebuild items only when mode changes
  (def db3 (if (not= old-mode new-mode)
             (put db2 :launcher/items (build-items db2 new-mode))
             db2))
  (def db4 (launcher/update-results db3))
  (def result-count (length (get db4 :launcher/results [])))
  (def selected (get db4 :launcher/selected 0))
  (put db4 :launcher/selected (clamp selected 0 (max 0 (- result-count 1)))))

(reg-event-handler :key
  (fn [cofx event]
    (def db (cofx :db))
    (when (get db :launcher/open?)
      (def info (event 1))
      (when (info :pressed)
        (def sym (info :sym))
        (def text (info :text))
        (def query (get db :launcher/query ""))
        (def selected (get db :launcher/selected 0))
        (def result-count (length (get db :launcher/results [])))

        (cond
          (= sym "Escape")
          {:dispatch [:launcher/close]}

          (= sym "Return")
          {:dispatch [:launcher/select]}

          (= sym "BackSpace")
          {:db (launcher/set-query db
                 (if (> (length query) 0)
                   (string/slice query 0 (- (length query) 1))
                   ""))}

          # Ctrl+W: delete word
          (and (= sym "w") (info :ctrl))
          {:db (launcher/set-query db
                 (do
                   (var end (length query))
                   (while (and (> end 0) (= (get query (- end 1)) (chr " ")))
                     (-- end))
                   (while (and (> end 0) (not= (get query (- end 1)) (chr " ")))
                     (-- end))
                   (string/slice query 0 end)))}

          # Ctrl+U: clear line
          (and (= sym "u") (info :ctrl))
          {:db (launcher/set-query db "")}

          (or (= sym "Up") (and (= sym "p") (info :ctrl)) (and (= sym "k") (info :ctrl)))
          {:db (put db :launcher/selected (max 0 (- selected 1)))}

          (or (= sym "Down") (and (= sym "n") (info :ctrl)) (and (= sym "j") (info :ctrl)))
          {:db (put db :launcher/selected (min (max 0 (- result-count 1))
                                               (+ selected 1)))}

          (= sym "Tab")
          (let [[mode _] (parse-mode query)
                next-mode (case mode :all :app :app :window :window :tag :tag :action :action :command :command :eval :eval :all)
                prefix (case next-mode :app "!" :window "@" :tag "#" :action ">" :command ":" :eval "=" "")]
            {:db (launcher/set-query db prefix)})

          # Regular text input
          (and (> (length text) 0) (not (info :ctrl)) (not (info :alt)) (not (info :super)))
          {:db (launcher/set-query db (string query text))})))))

# --- Pointer handling (launcher results) ---

(reg-event-handler :click
  (fn [cofx event]
    (def db (cofx :db))
    (when (get db :launcher/open?)
      (def id (get event 1 ""))
      (when (string/has-prefix? "result-" id)
        (def idx (scan-number (string/slice id 7)))
        (when idx
          {:db (put db :launcher/selected idx)
           :dispatch [:launcher/select]})))))

(reg-event-handler :scroll
  (fn [cofx event]
    (def db (cofx :db))
    (when (get db :launcher/open?)
      (def dir (get event 1 ""))
      (def selected (get db :launcher/selected 0))
      (def result-count (length (get db :launcher/results [])))
      (cond
        (= dir "up")
        {:db (put db :launcher/selected (max 0 (- selected 1)))}
        (= dir "down")
        {:db (put db :launcher/selected (min (max 0 (- result-count 1))
                                              (+ selected 1)))}))))

# --- Signal integration: tidepool signals can trigger the launcher ---

(reg-event-handler :tp/signal
  (fn [cofx event]
    (def name (get event 1 ""))
    (case name
      "open-launcher"
      (if (get (cofx :db) :launcher/open?)
        {:dispatch [:launcher/close]}
        {:dispatch [:launcher/open]})
      "close-launcher"
      {:dispatch [:launcher/close]})))

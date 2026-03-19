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

(defn- fuzzy-match [query label]
  "Case-insensitive substring match."
  (when (and query label)
    (string/find (string/ascii-lower query)
                 (string/ascii-lower label))))

(defn- filter-items [items query]
  (if (or (nil? query) (= query ""))
    items
    (filter |(fuzzy-match query ($ :label)) items)))

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

(defn- build-items [db mode]
  "Build the item list based on the current mode."
  (def tp (get db :tp {}))
  (def items @[])

  # Actions (from tidepool action registry)
  (when (= mode :action)
    (each act (get db :launcher/actions [])
      (def key (get act :key ""))
      (def label (string (act :name)
                         (when (> (length key) 0) (string "  [" key "]"))
                         (when (get act :desc)
                           (string " — " (act :desc)))))
      (array/push items {:label label
                         :kind :action
                         :action-name (act :name)})))

  # Apps (from desktop files, cached in db)
  (when (or (= mode :all) (= mode :app))
    (each app (get db :launcher/apps [])
      (array/push items {:label (app :name)
                         :kind :app
                         :exec (app :exec)})))

  # Windows
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

  # Tags
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

(defn- launcher/tp-socket-path []
  (let [runtime (os/getenv "XDG_RUNTIME_DIR")
        display (os/getenv "WAYLAND_DISPLAY")]
    (when (and runtime display)
      (string runtime "/tidepool-" display))))

# --- Subscriptions ---

(reg-sub :launcher/open?
  (fn [db] (get db :launcher/open? false)))

(reg-sub :launcher/query
  (fn [db] (get db :launcher/query "")))

(reg-sub :launcher/selected
  (fn [db] (get db :launcher/selected 0)))

(reg-sub :launcher/results
  (fn [db]
    (def items (get db :launcher/items []))
    (def query (get db :launcher/query ""))
    (def [mode stripped] (parse-mode query))
    (filter-items items stripped)))

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
         :bg (if active overlay-color bg)
         :radius 4 :pad [4 12] :align-y :center :gap 8}
    [:row {:w 4 :h 16 :bg (if active kind-color [0 0 0 0]) :radius 2}]
    [:text {:color (if active bright text-color) :size 14}
      (item :label)]])

(defn launcher-view []
  (def query (sub :launcher/query))
  (def results (sub :launcher/results))
  (def selected (sub :launcher/selected))
  (def reveal (anim :launcher/reveal))
  (def max-visible 12)
  (def total (length results))

  # Scroll offset: keep selected item visible
  (def scroll-off (max 0 (min (- selected (- max-visible 1))
                               (- total max-visible))))
  (def visible-end (min total (+ scroll-off max-visible)))

  (def alpha (math/floor (* reveal 255)))
  (def bg-a [(bg 0) (bg 1) (bg 2) alpha])

  [:col {:w :grow :h :grow :bg bg-a :radius 8 :pad 12}
    # Input field
    [:row {:h 40 :w :grow :bg [(surface-color 0) (surface-color 1) (surface-color 2) alpha]
           :radius 6 :pad [8 12] :align-y :center}
      [:text {:color text-color :size 16}
        (string query "│")]]
    # Results list
    [:col {:w :grow :h :grow :gap 2 :pad [8 0 0 0]}
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
    # Scan desktop apps (cached per open so we pick up new installs)
    (def apps (desktop-apps))
    # Deduplicate by name, keep first occurrence
    (def seen @{})
    (def unique-apps @[])
    (each app apps
      (def n (get app :name ""))
      (when (and (> (length n) 0) (not (get seen n)))
        (put seen n true)
        (array/push unique-apps app)))
    # Sort alphabetically
    (sort unique-apps |(< (get $0 :name "") (get $1 :name "")))
    (def db2 (put db :launcher/apps unique-apps))
    (def items (build-items db2 :all))
    {:db (-> db2
             (put :launcher/open? true)
             (put :launcher/query "")
             (put :launcher/selected 0)
             (put :launcher/items items))
     :surface {:create {:name :launcher
                        :layer :overlay
                        :width 600
                        :height 460
                        :anchor {:top true}
                        :margin {:top 200}
                        :keyboard-interactivity :exclusive}}
     :anim {:id :launcher/reveal :to 1 :duration 0.15 :easing :ease-out-cubic}
     # Request action list from tidepool via a separate query connection
     :ipc {:connect {:path (launcher/tp-socket-path)
                     :name :tp-query
                     :framing :netrepl
                     :handshake "\xFF{:name \"shoal-query\"}"
                     :event :tp-query/recv
                     :connected :tp-query/connected}}}))

(reg-event-handler :launcher/close
  (fn [cofx event]
    {:db (-> (cofx :db)
             (put :launcher/open? false)
             (put :launcher/query "")
             (put :launcher/items [])
             (put :launcher/selected 0))
     :surface {:destroy :launcher}
     :ipc {:disconnect {:name :tp-query}}}))

# -- Tidepool query connection (for action introspection) --

(reg-event-handler :tp-query/connected
  (fn [cofx event]
    {:ipc {:send {:name :tp-query
                  :data "(ipc/list-actions)\n"}}}))

(reg-event-handler :tp-query/recv
  (fn [cofx event]
    (def msg-type (get event 1))
    (def payload (get event 2))
    (when (= msg-type :return)
      (var result {:ipc {:disconnect {:name :tp-query}}})
      (try
        (do
          (def actions (json/decode payload true))
          (when (and actions (indexed? actions))
            (set result
              {:db (-> (cofx :db)
                       (put :launcher/actions actions)
                       (|(let [q (get $ :launcher/query "")
                               [mode stripped] (parse-mode q)]
                           (if (= mode :action)
                             (-> $
                                 (put :launcher/items (build-items $ :action))
                                 (put :launcher/selected 0))
                             $))))
               :ipc {:disconnect {:name :tp-query}}})))
        ([err]
          (eprintf "launcher: action list parse error: %s" (string err))))
      result)))

(reg-event-handler :launcher/select
  (fn [cofx event]
    (def db (cofx :db))
    (def items (get db :launcher/items []))
    (def query (get db :launcher/query ""))
    (def [mode stripped] (parse-mode query))
    (def results (filter-items items stripped))
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
        {:ipc {:send {:name :tidepool :data (string stripped "\n")}}
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
    {:ipc {:send {:name :tidepool
                  :data (string "(ipc/dispatch \"focus-window\" " wid ")\n")}}}))

# --- Keyboard handling (only when launcher is open) ---

(reg-event-handler :key
  (fn [cofx event]
    (def db (cofx :db))
    (when (get db :launcher/open?)
      (def info (event 1))
      (when (info :pressed)
        (def sym (info :sym))
        (def text (info :text))
        (def query (get db :launcher/query ""))
        (def items (get db :launcher/items []))
        (def selected (get db :launcher/selected 0))
        (def [mode stripped] (parse-mode query))
        (def results (filter-items items stripped))
        (def result-count (length results))

        (cond
          (= sym "Escape")
          {:dispatch [:launcher/close]}

          (= sym "Return")
          {:dispatch [:launcher/select]}

          (= sym "BackSpace")
          (let [new-query (if (> (length query) 0)
                            (string/slice query 0 (- (length query) 1))
                            "")
                [new-mode new-stripped] (parse-mode new-query)
                new-items (build-items db new-mode)
                new-results (filter-items new-items new-stripped)]
            {:db (-> db
                     (put :launcher/query new-query)
                     (put :launcher/items new-items)
                     (put :launcher/selected (clamp selected 0
                                              (max 0 (- (length new-results) 1)))))})

          # Ctrl+W: delete word
          (and (= sym "w") (info :ctrl))
          (let [# Find last space or mode prefix boundary
                new-query (do
                            (var end (length query))
                            # Skip trailing spaces
                            (while (and (> end 0) (= (get query (- end 1)) (chr " ")))
                              (-- end))
                            # Skip word chars
                            (while (and (> end 0) (not= (get query (- end 1)) (chr " ")))
                              (-- end))
                            (string/slice query 0 end))
                [new-mode new-stripped] (parse-mode new-query)
                new-items (build-items db new-mode)
                new-results (filter-items new-items new-stripped)]
            {:db (-> db
                     (put :launcher/query new-query)
                     (put :launcher/items new-items)
                     (put :launcher/selected (clamp selected 0
                                              (max 0 (- (length new-results) 1)))))})

          # Ctrl+U: clear line
          (and (= sym "u") (info :ctrl))
          (let [new-items (build-items db :all)]
            {:db (-> db
                     (put :launcher/query "")
                     (put :launcher/items new-items)
                     (put :launcher/selected 0))})

          (or (= sym "Up") (and (= sym "p") (info :ctrl)))
          {:db (put db :launcher/selected (max 0 (- selected 1)))}

          (or (= sym "Down") (and (= sym "n") (info :ctrl)))
          {:db (put db :launcher/selected (min (max 0 (- result-count 1))
                                               (+ selected 1)))}

          (= sym "Tab")
          (let [next-mode (case mode :all :app :app :window :window :tag :tag :action :action :command :command :eval :eval :all)
                prefix (case next-mode :app "!" :window "@" :tag "#" :action ">" :command ":" :eval "=" "")
                new-items (build-items db next-mode)]
            {:db (-> db
                     (put :launcher/query prefix)
                     (put :launcher/items new-items)
                     (put :launcher/selected 0))})

          # Regular text input
          (and (> (length text) 0) (not (info :ctrl)) (not (info :alt)) (not (info :super)))
          (let [new-query (string query text)
                [new-mode new-stripped] (parse-mode new-query)
                new-items (build-items db new-mode)
                new-results (filter-items new-items new-stripped)]
            {:db (-> db
                     (put :launcher/query new-query)
                     (put :launcher/items new-items)
                     (put :launcher/selected (clamp selected 0
                                              (max 0 (- (length new-results) 1)))))}))))))

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

# dmenu — stdin/stdout item picker
#
# Minimal module for dmenu compatibility mode. Reads items from
# :dmenu/items in the db (injected by Zig from stdin), presents
# them in a single overlay surface, and writes selection to stdout.

# --- Helpers ---

(defn- fuzzy-score [query label]
  "Fuzzy match with scoring. Returns score or nil."
  (when (and query label (> (length query) 0) (> (length label) 0))
    (def q (string/ascii-lower query))
    (def l (string/ascii-lower label))
    (def qlen (length q))
    (var qi 0)
    (var score 0)
    (var prev-match -2)
    (for li 0 (length l)
      (when (and (< qi qlen) (= (get q qi) (get l li)))
        (if (= (- li 1) prev-match) (+= score 4) (+= score 1))
        (when (or (= li 0)
                  (let [prev-ch (get l (- li 1))]
                    (or (= prev-ch (chr " ")) (= prev-ch (chr "-"))
                        (= prev-ch (chr "_")) (= prev-ch (chr "/")))))
          (+= score 3))
        (when (= qi li) (+= score 2))
        (set prev-match li)
        (++ qi)))
    (when (= qi qlen) score)))

(defn- filter-items [items query]
  (if (or (nil? query) (= query ""))
    items
    (let [scored (seq [item :in items
                       :let [s (fuzzy-score query item)]
                       :when s]
                   {:item item :score s})]
      (sort scored |(> ($0 :score) ($1 :score)))
      (map |($ :item) scored))))

(defn- clamp [v lo hi]
  (min hi (max lo v)))

# --- Subscriptions ---

(reg-sub :dmenu/query
  (fn [db] (get db :dmenu/query "")))

(reg-sub :dmenu/selected
  (fn [db] (get db :dmenu/selected 0)))

(reg-sub :dmenu/prompt
  (fn [db] (get db :dmenu/prompt ":")))

(reg-sub :dmenu/total
  (fn [db] (length (get db :dmenu/items []))))

(reg-sub :dmenu/results
  (fn [db]
    (def items (get db :dmenu/items []))
    (def query (get db :dmenu/query ""))
    (filter-items items query)))

# --- View ---

(def- bg (theme :bg))
(def- surface-color (theme :surface))
(def- overlay-color (theme :overlay))
(def- text-color (theme :text))
(def- bright (theme :bright))
(def- muted (theme :muted))
(def- subtle (theme :subtle))
(def- accent (theme :accent))

(defn- result-item [idx label selected]
  (def active (= idx selected))
  [:row {:w :grow :h 32
         :bg (if active overlay-color bg)
         :radius 4 :pad [4 12] :align-y :center :gap 8}
    [:row {:w 4 :h 16 :bg (if active accent [0 0 0 0]) :radius 2}]
    [:text {:color (if active bright text-color) :size 14} label]])

(defn dmenu-view []
  (def query (sub :dmenu/query))
  (def prompt (sub :dmenu/prompt))
  (def results (sub :dmenu/results))
  (def selected (sub :dmenu/selected))
  (def reveal (anim :dmenu/reveal))
  (def max-visible 12)
  (def total (length results))
  (def scroll-off (max 0 (min (- selected (- max-visible 1))
                               (- total max-visible))))
  (def visible-end (min total (+ scroll-off max-visible)))
  (def alpha (math/floor (* reveal 255)))

  [:col {:w 600 :h :grow :bg [(bg 0) (bg 1) (bg 2) alpha] :radius 8 :pad 12
         :align-x :center}
    # Input field
    [:row {:h 40 :w :grow
           :bg [(surface-color 0) (surface-color 1) (surface-color 2) alpha]
           :radius 6 :pad [8 12] :align-y :center :gap 8}
      [:text {:color muted :size 14} prompt]
      [:text {:color text-color :size 16}
        (string query "│")]]
    # Results list
    [:col {:w :grow :h :grow :gap 2 :pad [8 0 0 0]}
      ;(seq [i :range [scroll-off visible-end]
             :let [item (results i)]]
         (result-item i item selected))]
    # Footer
    [:row {:h 20 :w :grow :align-x :center :align-y :center}
      [:text {:color subtle :size 11}
        (string (length results) " / " (sub :dmenu/total))]]])

(reg-view dmenu-view)

# --- Event Handlers ---

(reg-event-handler :init
  (fn [cofx event]
    {:anim {:id :dmenu/reveal :to 1 :duration 0.15 :easing :ease-out-cubic}}))

(reg-event-handler :key
  (fn [cofx event]
    (def db (cofx :db))
    (def info (event 1))
    (when (info :pressed)
      (def sym (info :sym))
      (def text (info :text))
      (def query (get db :dmenu/query ""))
      (def items (get db :dmenu/items []))
      (def selected (get db :dmenu/selected 0))
      (def results (filter-items items query))
      (def result-count (length results))

      (cond
        (= sym "Escape")
        {:exit 1}

        (= sym "Return")
        (if (and (> result-count 0) (<= selected (- result-count 1)))
          {:stdout (results selected) :exit 0}
          # If no results but query has text, output the query itself
          (if (> (length query) 0)
            {:stdout query :exit 0}
            {:exit 1}))

        (= sym "BackSpace")
        (let [new-query (if (> (length query) 0)
                          (string/slice query 0 (- (length query) 1))
                          "")
              new-results (filter-items items new-query)]
          {:db (-> db
                   (put :dmenu/query new-query)
                   (put :dmenu/selected (clamp selected 0
                                          (max 0 (- (length new-results) 1)))))})

        (and (= sym "u") (info :ctrl))
        {:db (-> db (put :dmenu/query "") (put :dmenu/selected 0))}

        (and (= sym "w") (info :ctrl))
        (let [new-query (do
                          (var end (length query))
                          (while (and (> end 0) (= (get query (- end 1)) (chr " ")))
                            (-- end))
                          (while (and (> end 0) (not= (get query (- end 1)) (chr " ")))
                            (-- end))
                          (string/slice query 0 end))
              new-results (filter-items items new-query)]
          {:db (-> db
                   (put :dmenu/query new-query)
                   (put :dmenu/selected (clamp selected 0
                                          (max 0 (- (length new-results) 1)))))})

        (or (= sym "Up") (and (= sym "p") (info :ctrl)) (and (= sym "k") (info :ctrl)))
        {:db (put db :dmenu/selected (max 0 (- selected 1)))}

        (or (= sym "Down") (and (= sym "n") (info :ctrl)) (and (= sym "j") (info :ctrl)))
        {:db (put db :dmenu/selected (min (max 0 (- result-count 1))
                                           (+ selected 1)))}

        # Regular text input
        (and (> (length text) 0) (not (info :ctrl)) (not (info :alt)) (not (info :super)))
        (let [new-query (string query text)
              new-results (filter-items items new-query)]
          {:db (-> db
                   (put :dmenu/query new-query)
                   (put :dmenu/selected (clamp selected 0
                                          (max 0 (- (length new-results) 1)))))})))))

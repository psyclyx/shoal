# bar — default bar view
#
# Pure Janet view functions producing hiccup for a status bar.
# Layout: left (workspaces) | center (title) | right (clock, cpu, mem, bat)
#
# Uses subscriptions from tidepool.janet, clock.janet, sysinfo.janet.
# Theme colors are Catppuccin Mocha (base16) in 0-255 RGBA.

# -- Theme colors (Catppuccin Mocha, 0-255 RGBA) --

(def- bg      [30 30 46 255])
(def- surface [24 24 37 255])
(def- overlay [49 50 68 255])
(def- muted   [69 71 90 255])
(def- subtle  [88 91 112 255])
(def- text-color [205 214 244 255])
(def- accent  [137 180 250 255])
(def- bright  [180 190 254 255])

# -- Helper: pill wrapper --

(defn- pill [& children]
  [:row {:pad [4 8] :bg surface :radius 6}
    ;children])

# -- Workspace tags --

(defn- tag-view [idx tag]
  (if (tag :focused)
    [:row {:w 22 :h 22 :bg accent :radius 5 :align-x :center :align-y :center}
      [:text {:color bg :size 13} (string idx)]]
    [:row {:w 22 :h 22 :radius 5 :align-x :center :align-y :center}
      [:text {:color text-color :size 13} (string idx)]]))

(defn- workspaces-view []
  (def tags (sub :tp/tags))
  (def layout-name (sub :tp/layout))
  [:row {:gap 4 :align-y :center :pad [2 4] :bg surface :radius 6}
    ;(seq [i :range [1 10]  # tags 1-9
           :let [tag (get tags i {:focused false :occupied false})]
           :when (or (tag :focused) (tag :occupied))]
       (tag-view i tag))
    ;(if (and layout-name (> (length layout-name) 0))
       [[:row {:w 1 :h 14 :bg muted}]
        [:text {:color subtle :size 12} layout-name]]
       [])])

# -- Title --

(defn- title-view []
  (def title (sub :tp/title))
  (if (and title (> (length title) 0))
    [:text {:color text-color :size 14} title]
    [:text {:color subtle :size 14} ""]))

# -- Right-side modules --

(defn- clock-view []
  (pill [:text {:color text-color :size 14} (sub :clock/time)]))

(defn- cpu-view []
  (pill [:text {:color text-color :size 14} (sub :cpu/text)]))

(defn- mem-view []
  (pill [:text {:color text-color :size 14} (sub :mem/text)]))

(defn- bat-view []
  (def bat-text (sub :bat/text))
  (when bat-text
    (pill [:text {:color text-color :size 14} bat-text])))

# -- Root bar view --

(defn- bar-view []
  [:row {:w :grow :h :grow :pad [0 8] :bg bg :radius 8 :align-y :center}
    # Left: workspaces
    [:row {:w :grow :gap 6 :align-y :center}
      (workspaces-view)]
    # Center: title
    [:row {:w :grow :align-x :center :align-y :center}
      (title-view)]
    # Right: system info
    [:row {:w :grow :gap 6 :align-x :right :align-y :center}
      (cpu-view)
      (mem-view)
      (bat-view)
      (clock-view)]])

(reg-view bar-view)

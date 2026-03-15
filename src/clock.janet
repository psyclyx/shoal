# clock — time data source
#
# Uses :timer + os/date to update :clock in db every second.
# Pure Janet — no Zig I/O primitives needed.

(reg-event-handler :clock/tick
  (fn [cofx event]
    (def d (os/date (os/time) true))
    {:db (put (cofx :db) :clock
              {:hours (d :hours)
               :minutes (d :minutes)
               :seconds (d :seconds)
               :month (+ 1 (d :month))
               :month-day (d :month-day)
               :year (+ 1900 (d :year))
               :week-day (d :week-day)})}))

# Start the clock on init — piggyback on existing :init via :dispatch
(reg-event-handler :clock/start
  (fn [cofx event]
    {:dispatch [:clock/tick]
     :timer {:delay 1.0 :event [:clock/tick] :repeat true :id :clock}}))

# Subscriptions
(reg-sub :clock (fn [db] (get db :clock {})))
(reg-sub :clock/time [:clock]
  (fn [clock]
    (string/format "%02d:%02d" (get clock :hours 0) (get clock :minutes 0))))
(reg-sub :clock/date [:clock]
  (fn [clock]
    (string/format "%04d-%02d-%02d"
      (get clock :year 2000) (get clock :month 1) (get clock :month-day 1))))

# Subscriptions Design

Phase 3 of the shoal rearchitecture. Memoized derivations from db.

---

## Purpose

Subscriptions are the bridge between state (db) and views. They derive display
data from the db, memoized so views don't recompute unless inputs change.

```
event → handler → {:db new-db :render true}
                         ↓
                   subs recompute (lazy, memoized)
                         ↓
                   view fn consumes sub values → hiccup
```

---

## API

### Layer 2: db extractors

```janet
(reg-sub :active-tag
  (fn [db]
    (db :active-tag)))

(reg-sub :tags
  (fn [db]
    (db :tags)))
```

A layer 2 sub takes the db table and returns derived data. This is the common
case — most subs extract and transform data from db.

### Layer 3: sub-to-sub dependencies

```janet
(reg-sub :active-tag-name
  [:active-tag :tags]       ;; input signal declarations
  (fn [active-tag tags]
    (get tags active-tag)))
```

A layer 3 sub depends on other subs, not directly on db. The first argument is
a vector of sub-ids. The function receives those subs' current values as
positional arguments. It only recomputes when its input subs produce new values.

### Querying from views

```janet
(defn my-view []
  (let [tag (sub :active-tag)
        title (sub :title)]
    [:row {}
      [:text {} (string "Tag " tag)]
      [:text {} title]]))
```

`(sub :sub-id)` returns the current memoized value. Called during view
evaluation. If the sub hasn't been computed yet this cycle, it evaluates lazily.

---

## Memoization Strategy

### Generation-based cache invalidation

Each time the db changes (`:db` fx executes), a **generation counter**
increments. This is a single integer, cheap to compare.

Each sub caches:
- `gen` — the generation at which it was last computed
- `value` — the cached result
- `input-values` — for layer 3 subs, the input sub values used

When `(sub :sub-id)` is called:

1. **Layer 2 sub**: Compare current generation to cached `gen`. If different,
   recompute. If same, return cached `value`.
2. **Layer 3 sub**: Evaluate input subs first (recursively). Compare input
   values to cached `input-values` (via `deep=`). If any differ, recompute.
   If all same, return cached `value`.

### Why generation, not structural comparison of db?

The db is a mutable Janet table. We can't cheaply compare "did it change?"
structurally. But we know *exactly* when it changes — when `:db` fx fires.
So we use a monotonic counter as a proxy. This means:

- If a handler returns `{:db db}` (same table, same contents), subs still
  recompute. This is fine — handlers should only return `:db` when they've
  actually changed something.
- Layer 2 subs may recompute even when their specific slice of db didn't
  change. This is acceptable — sub functions should be cheap. If a sub is
  expensive, make it layer 3 and depend on cheaper subs that act as filters.

### Lazy evaluation

Subs are **not** eagerly recomputed after every event. They evaluate lazily
when queried by a view (or by a layer 3 sub). This means:

- Subs that no view uses are never computed
- Only the subs needed for the current render are evaluated
- The dependency graph is implicit in the call chain, not materialized

---

## Implementation

### Janet side (shoal.janet additions)

```janet
(def- sub-registry @{})   # :sub-id → {:fn f :deps [...] or nil}
(def- sub-cache @{})       # :sub-id → {:gen N :value V :inputs [...]}
(var- db-generation 0)

(defn reg-sub
  "Register a subscription.

  Layer 2: (reg-sub :id (fn [db] ...))
  Layer 3: (reg-sub :id [:dep1 :dep2] (fn [v1 v2] ...))"
  [sub-id & args]
  (match args
    [deps-vec sub-fn]
    (put sub-registry sub-id {:fn sub-fn :deps deps-vec})

    [sub-fn]
    (put sub-registry sub-id {:fn sub-fn :deps nil})

    _ (error "reg-sub: expected (id fn) or (id deps fn)")))

(defn sub
  "Query a subscription value. Evaluates lazily with memoization."
  [sub-id]
  (def entry (get sub-registry sub-id))
  (unless entry (error (string "sub: unknown subscription " sub-id)))

  (def cached (get sub-cache sub-id))

  (if (entry :deps)
    # Layer 3: depends on other subs
    (do
      (def input-vals (map sub (entry :deps)))
      (if (and cached (deep= input-vals (cached :inputs)))
        (cached :value)
        (let [val (apply (entry :fn) input-vals)]
          (put sub-cache sub-id {:gen db-generation
                                  :value val
                                  :inputs input-vals})
          val)))
    # Layer 2: depends on db
    (if (and cached (= (cached :gen) db-generation))
      (cached :value)
      (let [val ((entry :fn) *db*)]
        (put sub-cache sub-id {:gen db-generation :value val})
        val))))

(defn bump-generation
  "Called by Zig after :db fx executes. Increments the generation counter."
  []
  (++ db-generation))

(defn clear-sub-cache
  "Clear all cached subscription values. Called on hot reload."
  []
  (eachk k sub-cache (put sub-cache k nil)))
```

### Zig side changes

1. **`*db*` dynamic binding**: The db needs to be accessible to layer 2 subs.
   Two options:
   - Pass db as argument to `sub` — but then views need db too, ugly
   - Set a Janet dynamic var `*db*` before view evaluation — clean

   Use Janet's dynamic bindings: `(setdyn :db db)` before calling the view fn.
   Layer 2 subs read `(dyn :db)` instead of `*db*`. Actually simpler: Zig sets
   a module-level var before calling subs.

   Simplest: Zig calls a `set-db-for-subs` function that stores the current db
   in a module-level var that `sub` reads. Called once before view evaluation.

2. **Generation bump**: In `executeFx`, after processing `:db`, call
   `bump-generation` in Janet. This is a single function call.

3. **View evaluation flow**:
   ```
   after all events processed, if render_dirty:
     1. call set-db-for-subs(dispatch.db)  — make db visible to subs
     2. call view-fn() → hiccup tree       — subs evaluate lazily inside
     3. walk hiccup → Clay → GL
   ```

---

## What *db* Looks Like

Since subs need access to the db but `sub` takes only a sub-id:

```janet
(var- *current-db* nil)

(defn set-current-db [db] (set *current-db* db))

(defn sub [sub-id]
  # ... layer 2 subs call ((entry :fn) *current-db*)
  ...)
```

Zig calls `set-current-db` before view evaluation. Clean, no global state
leaking — it's set for the duration of one render pass.

---

## Integration with Event Loop

The dispatch cycle becomes:

```
1. process event queue (handlers may update db, set render_dirty)
2. if render_dirty:
   a. set-current-db(db)
   b. call root view fn → hiccup
      (subs evaluate lazily, memoized by generation)
   c. walk hiccup → Clay → GL
   d. render_dirty = false
```

Subs don't add a new phase — they're evaluated *inside* the view fn call,
on demand. The generation counter is the only new bookkeeping.

---

## Open Questions

1. **Should sub cache survive across renders?** Yes — that's the whole point.
   A sub that produced value V last render returns V again if db generation
   hasn't changed. Cache only clears on hot reload or explicit `clear-sub-cache`.

2. **What about non-db signals?** Animation values, surface dims, pointer
   position — these aren't in the db. For now, subs only derive from db.
   Animation is Zig-native (frame-rate). If we need pointer-reactive subs
   later, we can add more generation counters per signal source. YAGNI.

3. **Circular dependencies?** Layer 3 subs could form cycles. No protection
   for now — Janet will stack overflow. If it becomes a problem, add a
   "computing" flag per sub and error on re-entry. YAGNI.

4. **deep= cost for layer 3 input comparison?** For small input values (a
   keyword, a number, a short tuple), negligible. For large derived tables,
   could be expensive. Mitigation: keep subs small and focused. If a sub
   returns a large structure, make it layer 2 (generation check is free).

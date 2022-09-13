(def *is-debugging* false)

(defn expect
  "Returns the matched sequence of bytes in network byte order if the predicate holds, otherwise errors."
  [bytes start end &opt pred]
  (def bytes (slice bytes start end))
  (if (or (nil? pred) (pred bytes)) bytes ))

(defn is-type-valid
  "Returns true if the type is either 'I' or 'Q'"
  [v]
  (or (= v (chr "I")) (= v (chr "Q"))))

(defn read-client-message
  "Returns the parsed client message as a struct, or nil if it failed to parse."
  [connection]
  (def bytes (flatten (ev/chunk connection 9)))
  (if (= (length bytes) 9)
    (do
      (def type (expect bytes 0 1 (fn [bs] (is-type-valid (first bs)))))
      (def body (expect bytes 1 9))
      (struct :type (string/from-bytes (first type)) :body body))
  nil))

(defn integer/from-bytes
  "Given 4 bytes in little endian order, assemble a 4 byte integer"
  [b1 b2 b3 b4]
  (bor
    (blshift b1 0)
    (blshift b2 8)
    (blshift b3 16)
    (blshift b4 24)))

(defn parse-client-message
  "Given a client message struct, parses the message and returns the struct for the given message type."
  [message]
  (match message
    # handle message for inserting a timestamped price
    {:type "I" :body [t1 t2 t3 t4 p1 p2 p3 p4]}
    (struct
      :type "I"
      :timestamp (integer/from-bytes t4 t3 t2 t1)
      :price (integer/from-bytes p4 p3 p2 p1))
    # handle message for querying average price for a given time
    {:type "Q" :body [l1 l2 l3 l4 u1 u2 u3 u4]}
    (struct
      :type "Q"
      :mintime (integer/from-bytes l4 l3 l2 l1)
      :maxtime (integer/from-bytes u4 u3 u2 u1))))

(defn handle-insert
  "Execute an insertion, given the session."
  [{:peer peer :prices prices} time price]
  (put prices time price)
  nil)

(defn mean-of-prices-in-range
  "Returns the mean of the prices in the given range for a set of prices"
  [prices min-time max-time]
  (def result
    (->> (pairs prices)
         (filter (fn [[time price]] (and (>= time min-time) (<= time max-time))))
         (map (fn [[time price]] price))
         (mean)))
  (if (not (nan? result))
    (math/floor result)
    0))

(defn buffer/push-integer-in-nbo
  "Pushes the bytes of the passed integer to the buffer in network byte order."
  [buffer integer]
  (for i 0 4
    (buffer/push-byte buffer (band (brshift integer (* 8 (- 4 i 1))) 0xFF)))
  buffer)

(defn handle-query
  "Execute a mean query, given the session."
  [{:peer peer :prices prices} min-time max-time]
  (let [data (buffer)]
    (cond
      # invalid, return 0 in case of error
      (> min-time max-time) (buffer/push-integer-in-nbo data 0)
      (buffer/push-integer-in-nbo data (mean-of-prices-in-range prices min-time max-time)))))

(defn handle-client-message
  "Given a user message, prepare a response, returns a buffer."
  [session message]
  (match message
    {:type "I" :timestamp time :price price} (handle-insert session time price)
    {:type "Q" :mintime min :maxtime max} (handle-query session min max)))

(defmacro protect-or-break
  "Executes the body in a protect context, breaking with the protect return if it fails."
  [body]
  (with-syms [$status $value]
    ~(let [[,$status ,$value] (protect ,body)]
       (when (and *is-debugging* (not ,$status))
         (printf "encountered error: %s" ,$value))
       (when (not ,$status) (break [,$status ,$value]))
       [,$status ,$value])))

(defn handle-next-message
  "Handles the next message and returns a tuple of status, response."
  [connection session]
  (def [msg-ok? msg] (protect-or-break (read-client-message connection)))
  (def [parsed-msg-ok? parsed-msg] (protect-or-break (parse-client-message msg)))
  (def [ok? response] (protect-or-break (handle-client-message session parsed-msg)))
  [ok? response])

(defn create-session
  "Creates a new session struct for a given connection."
  [connection]
  (struct
    :peer (net/peername connection)
    :prices @{}))

(defn connection-handler 
  "Handles a connection in a separate fiber."
  [connection session]
  (forever
    (def [msg-ok? msg]
      (handle-next-message connection session))
    (if msg-ok?
      (when (not (nil? msg))
        (net/write connection msg))
      (break (:close connection)))))

(defn start-mean-server
  "Starts the means to an end server, handles incoming connections."
  [address port]
  (net/server address port
              (fn [connection]
                (def session (create-session connection))
                (ev/call connection-handler connection session))))

# Create mean-server that binds on * and listen on port 8080.
(start-mean-server "*" "8080")

(import spork/json)

(def *is-debugging* false)
(def *max-message-size* 1024)

# Create prime-server that binds on * and listen on port 8080.
(def prime-server (net/listen "*" "8080"))

(defn is-prime?
  "Returns true if the given number is prime, otherwise false."
  [n]
  (var cur-n 1)
  (var was-prime? nil)
  (def n-max (math/floor (math/sqrt n)))
  (while (nil? was-prime?)
    (when (= cur-n n-max)
      (set was-prime? true))
    (when (or (not (int? n))
              (= n 1) (< n 0)
              (and
                (not= cur-n 1)
                (= (% n cur-n) 0)))
      (set was-prime? false))
    (++ cur-n))
  was-prime?)

(defn create-response
  "Creates a response given the message, return a tuple of the success value and the result."
  [msg-dict]
  (match msg-dict
      (@{"method" "isPrime" "number" n} (number? n)) [true @{"method" "isPrime" "prime" (is-prime? n)}]
      any [false @{:why "malformed response! you're getting disconnected!"}]))

(defn ev/read-until
  "Reads from the stream until a given value is encountered, returns nil if eof is encountered"
  [connection v]
  (var found? false)
  (var read-buffer (buffer/new 128))
  (while (not found?)
    (def current-value (ev/read connection 1))
    (when (= current-value nil) (break))
    (buffer/push read-buffer current-value)
    (set found? (deep= current-value v)))
  (if found?
    read-buffer
    nil))

(defn handle-message
  "Parses the message and returns a tuple of status, response."
  [connection]
  (def msg (ev/read-until connection @"\n"))
  (when *is-debugging* (prinf "got request with message: %s" (string msg)))
  (def [msg-valid? msg-dict] (protect (json/decode (string msg))))
  (def [ok? response] (create-response msg-dict))
  [ok? (json/encode response)])

(defn connection-handler 
  "Handles a connection in a separate fiber."
  [connection]
  (forever
    (def [msg-ok? msg]
      (handle-message connection))
    (if (not (nil? msg))
      (do
        (def response (string msg "\n"))
        (when *is-debugging*
          (prinf "responded with: %s" response))
        (net/write connection response)
        (when (not msg-ok?)
          (break (:close connection))))
      (break (:close connection)))))

(defn start-prime-server
  "Starts the prime server, handles incoming connections."
  []
  (forever
    (def connection (net/accept prime-server))
    (ev/call connection-handler connection)))

(start-prime-server)

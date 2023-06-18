(import spork)

(def *max-name-length* 32)
(def *max-message-length* 1024)
(def *is-debugging* true)

(defn ev/read-until
  "Reads from the stream until a given value is encountered, returns nil if eof is encountered"
  [connection max v]
  (var found? false)
  (var read-buffer (buffer/new max))
  (while (not found?)
    (def current-value (ev/read connection 1))
    (when (= current-value nil) (break))
    (buffer/push read-buffer current-value)
    (set found? (deep= current-value v)))
  (if found?
    read-buffer
    nil))

(defn is-valid-name?
  "Validates a client's name."
  [name]
  # this is so extremely cursed, pls janet why ur regex no good
  (case
    (= (length name) 0) false
    (= (string/join (spork/regex/match "([aA-zZ0-9])+" name)) name)))

(defn handle-client-server-message
  "Handles a message from the server to the client."
  [connection name message]
  (prin (string/format "%s got message: %s" name message))
  (ev/write connection message))

(defn handle-client-disconnect
  "Handles disconnecting a client, with an optional informational message first."
  [connection name &opt msg]
  (when (not (nil? msg)) (protect (ev/write msg)))
  (protect (ev/give-supervisor :disconnect name))
  (:close connection))

(defn handle-client-messages
  "Handles a connected clients messages."
  [connection name]
  (forever
    (def msg (ev/read-until connection *max-message-length* @"\n"))
    (if (or (nil? msg) (= (length msg) 0))
      (do
        (handle-client-disconnect connection name)
        (break))
      (ev/give-supervisor :message name (string/trim msg)))
    (ev/sleep 0.1)))

(defn handle-client-loop
  "Handles a connected client."
  [connection name]
  (def client-channel (ev/chan))
  (ev/give-supervisor :connect client-channel name)
  (def client-net-channel (ev/go (fn [] (handle-client-messages connection name))))
  (forever
    (match
      (ev/select client-channel)
      [:take ch msg] (handle-client-server-message connection name msg)
      [:close ch]
        (do
          (handle-client-disconnect connection name)
          (break)))))

(defn client-handler
  "Handles a new client connection in a separate fiber."
  [connection]
  (net/write connection "Welcome to budgetchat! What should I call you?\n")
  (def client-name (string/trim (net/read connection *max-name-length*)))
  (if (is-valid-name? client-name)
    (handle-client-loop connection client-name)
    (handle-client-disconnect connection client-name "Invalid client name, disconnecting you!\n")))

(defn send-message
  "Sends a message to a single specific client."
  [client-channel message]
  (ev/give client-channel (string message "\n")))

(defn broadcast-message
  "Handles broadcasting a message from a specific client, to all except the sender."
  [clients from-client-channel name message]
  (print (string/format "%s sent message: %s" name message))
  (loop [[name {:channel client-channel}] :pairs clients]
    (when (not (= from-client-channel client-channel))
      (send-message client-channel message))))

(defn presence-notification
  "Handles telling a new client what users are currently on the server."
  [clients client-channel name]
  (def all-clients-str
    (string/join (filter (fn [e] (not= e name)) (keys clients)) ", "))
  (send-message
    client-channel
    (string/format "* The room contains: %s" all-clients-str)))

(defn announce-new-client
  "Handles announcing a new client to all current clients on the server."
  [clients new-client-channel new-client-name]
  (broadcast-message
    clients new-client-channel new-client-name
    (string/format "* %s has entered the room" new-client-name)))

(defn announce-leaving-client
  "Handles announcing a client leaving to all current clients on the server."
  [clients leaving-client-channel leaving-client-name]
  (broadcast-message
    clients leaving-client-channel leaving-client-name
    (string/format "* %s has left the room" leaving-client-name)))

(defn client-message
  "Handles broadcasting a specific client's message to all other connected clients."
  [clients from-client-channel name message]
  (broadcast-message
    clients from-client-channel name
      (string/format "[%s] %s" name message)))

(defn server-handler
  "Handles any notifications from clients that may need a server response."
  [@{:channel channel :clients clients}]
  (forever
    (match (ev/take channel)
      [:connect client-channel name]
        (do
          (print (string/format "%s connected! announcing..." name))
          (put clients name {:channel client-channel})
          (announce-new-client clients client-channel name)
          (presence-notification clients client-channel name))
      [:message name message]
        (do
          (def client-channel ((get clients name) :channel))
          (client-message clients client-channel name message))
      [:disconnect name]
        (do
          (def client (get clients name))
          (when (not (nil? client))
            (def client-channel (client :channel))
            (announce-leaving-client clients client-channel name)
            (print (string/format "%s was disconnected!" name))
            (:close client-channel)
            (put clients name nil))))))

(defn create-server
  "Creates a new instance of the chat server."
  [address port]

  (def server-clients @{})
  (def server-channel (ev/chan))
  (def server-instance @{:channel server-channel :clients server-clients})
  (ev/go server-handler server-instance)

  (net/server address port
              (fn [connection]
                # Handle any connections as soon as they arrive
                (ev/go client-handler connection server-channel))))

(create-server "*" "8080")

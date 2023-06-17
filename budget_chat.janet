(import spork)

(def *max-name-length* 32)
(def *max-message-length* 1024)

(defn echo-handler 
  "Handles a connection in a separate fiber."
  [connection]
  (forever
    (def msg (ev/read connection 1024))
    (if (not (nil? msg))
      (net/write connection msg)
      (break (:close connection)))))

(defn is-valid-name?
  "Validates a client's name."
  [name]
  # this is so extremely cursed, pls janet why ur regex no good
  (= (string/join (spork/regex/match "([aA-zZ0-9])+" name)) name))

(defn handle-client-server-message
  "Handles a message from the server to the client."
  [connection message]
  (net/write connection message))

(defn handle-client-message-to-server
  "Handles a message from the client to the server."
  [name message]
  (ev/give-supervisor :message name message))

(defn handle-client-messages
  "Handles a connected clients messages."
  [connection name]
  (def msg (ev/read connection *max-message-length*))
  (ev/give-supervisor msg))

(defn handle-client-loop
  "Handles a connected client."
  [connection name]
  (def client-channel (ev/chan))
  (def client-net-channel (ev/go (fn [] (handle-client-messages connection name)) nil client-channel))
  (ev/give-supervisor :connect client-channel name)
  (forever
    # we wait for either a message from the server, or from the network
    (match
      (ev/select
        client-channel)
      [:take ch msg]
        (do
          (when (= ch client-channel)
            (handle-client-server-message connection msg))
          (when (= ch client-net-channel)
            (handle-client-message-to-server name msg)))
      [:close _] (break))))

(defn handle-client-disconnect
  "Handles disconnecting a client, with an optional informational message first."
  [connection name &opt msg]
  (when (not (nil? msg)) (net/write msg))
  (ev/give-supervisor :disconnect name)
  (:close connection))

(defn client-handler
  "Handles a new client connection in a separate fiber."
  [connection]
  (net/write connection "Welcome to budgetchat! What should I call you?\n")
  (def client-name (string/trim (net/read connection *max-name-length*)))
  (if (is-valid-name? client-name)
    (handle-client-loop connection client-name)
    (handle-client-disconnect connection client-name "Invalid client name, disconnecting you!\n")))

(defn broadcast-message
  "Handles broadcasting a message from a specific client, to all except the sender"
  [clients from-client-channel message]
  (loop [[name {:channel client-channel}] :pairs clients]
    (when (not (= from-client-channel client-channel))
      (ev/give client-channel
        (string/format message)))))

(defn presence-notification
  "Handles telling a new client what users are currently on the server."
  [clients client-channel name]
  # TODO: actually build the string with all clients here
  (def all-clients-str
    (string/join
      (filter (fn [e] (not= e name)) (keys clients))
      ", "))
  (ev/give client-channel (string/format "* The room contains: %s \n" all-clients-str)))

(defn announce-new-client
  "Handles announcing a new client to all current clients on the server."
  [clients new-client-channel new-client-name]
  (broadcast-message
    clients new-client-channel
    (string/format "* %s has entered the room\n" new-client-name)))

(defn announce-leaving-client
  "Handles announcing a client leaving to all current clients on the server."
  [clients leaving-client-channel leaving-client-name]
  (broadcast-message
    clients leaving-client-channel
    (string/format "* %s has left the room\n" leaving-client-name)))

(defn client-message
  "Handles broadcasting a specific client's message to all other connected clients."
  [clients from-client-channel name message]
  (broadcast-message
    clients from-client-channel
    (string/format "[%s] %s\n" name message)))

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
          (print (string/format "[%s] %s" name message))
          (client-message clients client-channel name message))
      [:disconnect name]
        (do
          (def client (get clients name))
          (when (not (nil? client))
            (def client-channel (client :channel))
            (print (string/format "%s was disconnected!" name))
            (announce-leaving-client clients client-channel name)
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

# Create echo-server that binds on * and listen on port 8000.
(def echo-server (net/listen "*" "8080"))

(defn close-if-valid
  "Closes the connection if it is still valid"
  [connection]
  (when (not (nil? connection))
    (:close connection)))

(defn handler 
  "Handles a connection in a separate fiber."
  [connection]
  (forever
    (def msg (ev/read connection 1024))
    (if (not (nil? msg))
      (net/write connection msg)
      (break (:close connection)))))

# Handle any connections as soon as they arrive
(forever
 (def connection (net/accept echo-server))
 (ev/call handler connection))

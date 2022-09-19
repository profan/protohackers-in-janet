(defn echo-handler 
  "Handles a connection in a separate fiber."
  [connection]
  (forever
    (def msg (ev/read connection 1024))
    (if (not (nil? msg))
      (net/write connection msg)
      (break (:close connection)))))

# Handle any connections as soon as they arrive
(net/server "*" "8080"
            (fn [connection]
              (ev/call echo-handler connection)))

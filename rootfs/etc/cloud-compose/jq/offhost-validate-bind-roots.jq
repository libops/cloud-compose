all(.services[].volumes[]?;
  .type != "bind" or
  (.source | type == "string" and
    (. == $data_root or startswith($data_root + "/") or
     . == $volumes_root or startswith($volumes_root + "/")) and
    (explode | all(.[]; . >= 32 and . != 127)) and
    (contains("//") | not) and
    length > 0))

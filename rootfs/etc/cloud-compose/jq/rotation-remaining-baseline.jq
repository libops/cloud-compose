$after | map(select(. as $name | $before | index($name))) | sort

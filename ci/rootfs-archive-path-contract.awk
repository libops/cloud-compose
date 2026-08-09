$0 !~ /^rootfs\// { bad = 1 }
/(^|\/)\.\.($|\/)/ { bad = 1 }
END { exit bad }

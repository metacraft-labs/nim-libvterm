## test_replies_to_queries.nim -- the answers the emulated terminal queues for
## the program's queries, taken with `takeReplies`.

import nim_libvterm

block:
  var s = newScreen(5, 20)
  doAssert s.takeReplies() == ""            # nothing asked, nothing to answer

  s.feed("\x1b[c")                          # Primary Device Attributes
  doAssert s.takeReplies() == "\x1b[?1;2c"
  doAssert s.takeReplies() == ""            # taking empties the queue

  s.feed("\x1b[3;7H\x1b[6n")                # cursor position report
  doAssert s.takeReplies() == "\x1b[3;7R"

  s.feed("\x1b[?6n")                        # DECXCPR: the private-marker form
  doAssert s.takeReplies() == "\x1b[?3;7R"

  s.feed("\x1b[5n\x1b[>c")                  # DSR status, then DA2, in order
  doAssert s.takeReplies() == "\x1b[0n\x1b[>0;100;0c"

  s.feed("hello")                           # text queues no answer
  doAssert s.takeReplies() == ""

  # A query split across two feeds is answered once it is complete.
  s.feed("\x1b[")
  doAssert s.takeReplies() == ""
  s.feed("c")
  doAssert s.takeReplies() == "\x1b[?1;2c"

  echo "test_replies_to_queries OK"

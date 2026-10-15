### Internal

- The default-sink stall probe and the flood test under a full stdout no longer assert a read-ahead peak under twice the limit. Reading pauses between deliveries of the worker's stdout, and the VM can hand over about 4 MiB as one delivery, so a valid peak reached 8.5 MB on a loaded runner. They now assert the bound the pause logic gives: the limit plus twice the largest delivery and twice the largest frame, recorded by the channel. The channel's documentation states that bound.

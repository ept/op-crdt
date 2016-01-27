module CRDT
  # Keeps track of what each peer knows about each other peer. This structure saves us from having
  # to send around full vector clocks all the time: instead, peers can just send diffs of their
  # vector clock when it is updated, and those diffs are applied to this matrix. It also enables
  # us to use a peer index (a small number) instead of a full 256-bit peer ID, which further
  # reduces message sizes.
  #
  # Each peer has its own mapping from peer IDs to peer indexes (to avoid having to coordinate
  # between peers to agree on a mapping). The only requirement is that for each peer, index 0 is
  # that peer itself. The other indexes are assigned sequentially in arbitrary order by each peer.
  # This matrix keeps track of each peer's assignment of peer indexes to peer IDs.
  class PeerMatrix

    # One entry in a vector clock. The +peer_id+ is the hex string representing a peer; the
    # +peer_index+ is the number we have locally assigned to that peer; and +msg_count+ is the
    # number of messages we have received from that peer.
    PeerVClockEntry = Struct.new(:peer_id, :peer_index, :msg_count)

    # A clock update is a special kind of operation, which can be broadcast from one peer to other
    # peers. When a ClockUpdate is sent, it reflects the messages received by the sender (i.e. which
    # operations the sender has previously received from other peers). This is used to track the
    # causal dependencies between operations.
    class ClockUpdate
      # When building up locally, no argument is given. When received from a remote peer, the
      # argument is an array of PeerVClockEntry objects.
      def initialize(entries=nil)
        @entries = entries
        # A hash, where the key is a peer ID (hex string) and the value is a PeerVClockEntry object.
        @update_by_peer_id = {}
      end

      def add_peer(peer_id, peer_index)
        raise 'Cannot modify clock update from remote peer' if @entries
        @update_by_peer_id[peer_id] = PeerVClockEntry.new(peer_id, peer_index, 0)
      end

      def record_update(peer_id, peer_index, msg_count)
        raise 'Cannot modify clock update from remote peer' if @entries
        @update_by_peer_id[peer_id] ||= PeerVClockEntry.new(nil, peer_index, 0)
        @update_by_peer_id[peer_id].msg_count = msg_count
      end

      def empty?
        (!@entries || @entries.empty?) && @update_by_peer_id.empty?
      end

      def entries
        @entries || @update_by_peer_id.values.sort {|e1, e2| e1.peer_index <=> e2.peer_index }
      end
    end

    # matrix is an array of arrays (i.e. a 2D array).
    # matrix[peer1_index][peer2_index] is a PeerVClockEntry object.
    # Each such object records how many operations peer1 has seen from peer2.
    # peer1_index is according to this peer's local index assignment (see index_by_peer_id);
    # peer2_index is according to peer1's index assignment.
    attr_reader :matrix

    # A hash, where the key is a peer ID (as hex string) and the value is the index that this peer
    # has locally assigned to that peer ID. The indexes must be strictly sequential.
    attr_reader :index_by_peer_id

    # This is used to record any operations we see from other peers, so that we can broadcast vector
    # clock diffs to others.
    attr_reader :local_clock_update


    def initialize(own_peer_id)
      @matrix = [[PeerVClockEntry.new(own_peer_id, 0, 0)]]
      @index_by_peer_id = {own_peer_id => 0}
      @local_clock_update = ClockUpdate.new
    end

    # The peer ID (globally unique hex string) for the local device.
    def own_peer_id
      @matrix[0][0].peer_id
    end

    # When we get a message from +origin_peer_id+, it may refer to another peer by an integer index
    # +remote_peer_index+. This method translates +remote_peer_index+ (which is meaningful only in
    # the context of messages from +origin_peer_id+) to the corresponding peer ID (a hex string that
    # is globally unique).
    def remote_index_to_peer_id(origin_peer_id, remote_peer_index)
      entry = @matrix[peer_id_to_index(origin_peer_id)][remote_peer_index]
      entry && entry.peer_id or raise "No peer ID for index #{remote_peer_index}"
    end

    # Translates a globally unique peer ID into a local peer index. If the peer ID is not already
    # known, it is added to the matrix and assigned a new index.
    def peer_id_to_index(peer_id)
      index = @index_by_peer_id[peer_id]
      return index if index

      if (@index_by_peer_id.size != @matrix.size) ||
         (@index_by_peer_id.size != @matrix[0].size) ||
          @matrix[0].any? {|entry| entry.peer_id == peer_id }
        raise 'Mismatch between vector clock and peer list'
      end

      index = @index_by_peer_id.size
      @index_by_peer_id[peer_id] = index
      @matrix[0][index] = PeerVClockEntry.new(peer_id, index, 0)
      @matrix[index] = [PeerVClockEntry.new(peer_id, 0, 0)]
      local_clock_update.add_peer(peer_id, index)
      index
    end

    # Indicates that the peer +origin_peer_id+ has assigned an index of +subject_peer_index+ to the
    # peer +subject_peer_id+. Calling this method registers the mapping, so that subsequent calls to
    # +remote_index_to_peer_id+ can resolve the index. Returns the appropriate PeerVClockEntry.
    def peer_index_mapping(origin_peer_id, subject_peer_id, subject_peer_index)
      vclock = @matrix[peer_id_to_index(origin_peer_id)]
      entry = vclock[subject_peer_index]

      if entry
        raise 'Contradictory peer index assignment' if subject_peer_id && subject_peer_id != entry.peer_id
        entry
      else
        raise 'Non-consecutive peer index assignment' if subject_peer_index != vclock.size
        raise 'New peer index assignment without ID' if subject_peer_id.nil?
        entry = PeerVClockEntry.new(subject_peer_id, subject_peer_index, 0)
        vclock[subject_peer_index] = entry
      end
    end

    # Processes a clock update from a remote peer and applies it to the local state. The update
    # indicates that +origin_peer_id+ has received various operations from other peers, and also
    # documents which peer indexes +origin_peer_id+ has assigned to those peers.
    def apply_clock_update(origin_peer_id, update)
      update.entries.each do |new_entry|
        old_entry = peer_index_mapping(origin_peer_id, new_entry.peer_id, new_entry.peer_index)
        raise 'Clock update went backwards' if old_entry.msg_count > new_entry.msg_count
        old_entry.msg_count = new_entry.msg_count
      end
    end

    # Increments the message counter for the local peer, indicating that a message has been
    # broadcast to other peers.
    def increment_sent_messages
      @matrix[0][0].msg_count += 1
    end

    # Increments the message counter for a particular peer, indicating that we have processed a
    # message that originated on that peer. In other words, this moves the vector clock forward.
    def processed_incoming_msg(origin_peer_id, msg_count)
      origin_index = peer_id_to_index(origin_peer_id)
      local_entry  = @matrix[0][origin_index]
      remote_entry = @matrix[origin_index][0]

      # We normally expect the msg_count for a peer to be monotonically increasing. However, there's
      # a possible scenario in which a peer sends some messages and then crashes before writing its
      # state to stable storage, so when it comes back up, it reverts back to a lower msg_count. We
      # should detect when this happens, and replay the lost messages from another peer.
      raise "peerID mismatch: #{local_entry.peer_id} != #{origin_peer_id}" if local_entry.peer_id != origin_peer_id
      raise "msg_count for #{origin_peer_id} went backwards"  if local_entry.msg_count + 1 > msg_count
      raise "msg_count for #{origin_peer_id} jumped forwards" if local_entry.msg_count + 1 < msg_count

      local_entry.msg_count = msg_count
      remote_entry.msg_count = msg_count

      local_clock_update.record_update(origin_peer_id, origin_index, msg_count)
    end

    # Returns true if operations originating on the given peer ID are ready to be delivered to the
    # application, and false if they need to be buffered. Operations are causally ready if all
    # operations they may depend on (which had been processed by the time that operation was
    # generated) have already been applied locally. We assume that pairwise communication between
    # peers is totally ordered, i.e. that messages from one particular peer are received in the same
    # order as they were sent.
    def causally_ready?(remote_peer_id)
      local = @matrix[0].each_with_object(Hash.new(0)) do |entry, vclock|
        vclock[entry.peer_id] = entry.msg_count
      end
      remote = @matrix[peer_id_to_index(remote_peer_id)].each_with_object(Hash.new(0)) do |entry, vclock|
        vclock[entry.peer_id] = entry.msg_count
      end

      (local.keys | remote.keys).all? do |peer_id|
        (peer_id == remote_peer_id) || (local[peer_id] >= remote[peer_id])
      end
    end

    # Resets the tracking of messages received from other peers. This is done after a clock update
    # has been broadcast to other peers, so that we only transmit a diff of changes to the clock
    # since the last clock update.
    def reset_clock_update
      @local_clock_update = ClockUpdate.new
    end
  end
end
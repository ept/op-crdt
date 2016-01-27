require 'openssl'

module CRDT
  # A pair of logical timestamp (Lamport clock, which is just a number) and peer ID (256-bit hex
  # string that uniquely identifies a particular device). A peer increments its timestamp on every
  # operation, so this pair uniquely identifies a particular object, e.g. an element in a list.
  # It also provides a total ordering that is consistent with causality: if operation A happened
  # before operation B, then A's ItemID is lower than B's ItemID. The ordering of concurrent
  # operations is deterministic but arbitrary.
  class ItemID < Struct.new(:logical_ts, :peer_id)
    include Comparable

    def <=>(other)
      return nil unless other.respond_to?(:logical_ts) && other.respond_to?(:peer_id)
      return +1 if self.logical_ts > other.logical_ts
      return -1 if self.logical_ts < other.logical_ts
      self.peer_id <=> other.peer_id
    end
  end

  class Peer
    include Encoding

    # A message is the unit at which a peer broadcasts information to other peers.
    Message = Struct.new(:origin_peer_id, :msg_count, :operations)

    # Pseudo-operation, used to signal that all operations within a message have been processed.
    MessageProcessed = Struct.new(:msg_count)

    # 256-bit hex string that uniquely identifies this peer.
    attr_reader :peer_id

    # Keeps track of the key facts that we know about our peers.
    attr_reader :peer_matrix

    # CRDT data structure (TODO generalise this)
    attr_reader :ordered_list

    # Lamport clock
    attr_accessor :logical_ts

    # Loads a peer's state from a file with the specified file path, or the specified IO object.
    def self.load(file)
      if file.is_a? String
        File.open(file, 'rb') {|io| Encoding.load(io) }
      else
        Encoding.load(file)
      end
    end

    # Initializes a new peer instance with default state. If no peer ID is given, it is assigned a
    # new random peer ID (256-bit hex string).
    def initialize(peer_id=nil)
      @peer_id = peer_id || bin_to_hex(OpenSSL::Random.random_bytes(32))
      @peer_matrix = PeerMatrix.new(@peer_id)
      @ordered_list = OrderedList.new(self)
      @logical_ts = 0
      @send_buf = []
      @recv_buf = {} # map of origin_peer_id => array of operations
    end

    # Returns true if this peer has buffered information that should be broadcast to other peers.
    def anything_to_send?
      !@send_buf.empty?
    end

    # Generates a new unique ItemID for use within the CRDT.
    def next_id
      @logical_ts += 1
      ItemID.new(@logical_ts, peer_id)
    end

    # Called by the CRDT to enqueue an operation to be broadcast to other peers. Does not send the
    # operation immediately, just puts it in a buffer.
    def send_operation(operation)
      # Record causal dependencies of the operation before the operation itself
      if !peer_matrix.local_clock_update.empty?
        @send_buf << peer_matrix.local_clock_update
        peer_matrix.reset_clock_update
      end

      @send_buf << operation
    end

    # Returns a message that should be sent to remote peers. Resets the buffer of pending
    # operations, so the same operations won't be returned again.
    def make_message
      if !peer_matrix.local_clock_update.empty?
        @send_buf << peer_matrix.local_clock_update
        peer_matrix.reset_clock_update
      end

      message = Message.new(peer_id, peer_matrix.increment_sent_messages, @send_buf)
      @send_buf = []
      message
    end

    # Receives a message from a remote peer. The operations will be applied immediately if they are
    # causally ready, or buffered until later if dependencies are missing.
    def process_message(message)
      @recv_buf[message.origin_peer_id] ||= []
      @recv_buf[message.origin_peer_id].concat(message.operations)
      @recv_buf[message.origin_peer_id] << MessageProcessed.new(message.msg_count)
      while apply_operations_if_ready; end
    end

    private

    # Checks if there are any causally ready operations in the receive buffer that we can apply, and
    # if so, applies them. Returns false if nothing was applied, and returns true if something was
    # applied. Keep calling this method in a loop until it returns false, to ensure all ready
    # buffers are drained.
    def apply_operations_if_ready
      ready_peer_id, ready_ops = @recv_buf.detect do |peer_id, ops|
        peer_matrix.causally_ready?(peer_id) && !ops.empty?
      end
      return false if ready_peer_id.nil?

      while ready_ops.size > 0
        operation = ready_ops.shift

        if operation.is_a? PeerMatrix::ClockUpdate
          peer_matrix.apply_clock_update(ready_peer_id, operation)

          # Applying the clock update might make the following operations causally non-ready, so we
          # stop processing operations from this peer and check again for causal readiness.
          return true

        elsif operation.is_a? MessageProcessed
          peer_matrix.processed_incoming_msg(ready_peer_id, operation.msg_count)

        else
          @logical_ts = operation.logical_ts if @logical_ts < operation.logical_ts
          ordered_list.apply_operation(operation)
        end
      end

      true # Finished this peer, now another peer's operations might be causally ready
    end
  end
end
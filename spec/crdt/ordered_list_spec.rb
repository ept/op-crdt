require 'crdt'

RSpec.describe CRDT::OrderedList do
  context '#to_a' do
    it 'should be empty by default' do
      peer = CRDT::Peer.new(:peer1)
      expect(peer.ordered_list.to_a).to eq []
    end

    it 'should contain any inserted items' do
      peer = CRDT::Peer.new(:peer1)
      peer.ordered_list.insert(0, :a).insert(1, :b).insert(0, :c)
      expect(peer.ordered_list.to_a).to eq [:c, :a, :b]
    end

    it 'should omit any deleted items' do
      peer = CRDT::Peer.new(:peer1)
      peer.ordered_list.insert(0, :a).insert(1, :b).delete(0)
      expect(peer.ordered_list.to_a).to eq [:b]
    end
  end

  context 'generating operations' do
    it 'should be empty by default' do
      peer = CRDT::Peer.new(:peer1)
      expect(peer.flush_operations).to eq []
    end

    it 'should include details of an insert operation' do
      peer = CRDT::Peer.new(:peer1)
      peer.ordered_list.insert(0, :a)
      expect(peer.flush_operations).to eq [
        CRDT::OrderedList::InsertOp.new(nil, CRDT::ItemID.new(1, :peer1), :a)
      ]
    end

    it 'should assign monotonically increasing clock values to operations' do
      peer = CRDT::Peer.new(:peer1)
      peer.ordered_list.insert(0, :a).insert(1, :b).insert(2, :c)
      ops = peer.flush_operations
      expect(ops.map {|op| op.new_id.logical_ts }).to eq [1, 2, 3]
      expect(ops.map {|op| op.value }).to eq [:a, :b, :c]
    end

    it 'should reference prior inserts in later operations' do
      peer = CRDT::Peer.new(:peer1)
      peer.ordered_list.insert(0, :a).insert(1, :b).insert(2, :c).delete(1)
      ops = peer.flush_operations
      expect(ops[0].reference_id).to eq nil
      expect(ops[1].reference_id).to eq CRDT::ItemID.new(1, :peer1)
      expect(ops[2].reference_id).to eq CRDT::ItemID.new(2, :peer1)
      expect(ops[3].delete_id).to    eq CRDT::ItemID.new(2, :peer1)
    end

    it 'should include details of a delete operation' do
      peer = CRDT::Peer.new(:peer1)
      peer.ordered_list.insert(0, :a).delete(0)
      expect(peer.flush_operations.last).to eq (
        CRDT::OrderedList::DeleteOp.new(CRDT::ItemID.new(1, :peer1), CRDT::ItemID.new(2, :peer1))
      )
    end

    it 'should flush the operation list when called' do
      peer = CRDT::Peer.new(:peer1)
      peer.ordered_list.insert(0, :a).delete(0)
      peer.flush_operations
      expect(peer.flush_operations).to eq []
    end
  end

  context 'applying remote operations' do
    it 'should apply changes from another peer' do
      peer1 = CRDT::Peer.new(:peer1)
      peer2 = CRDT::Peer.new(:peer2)
      peer1.ordered_list.insert(0, :a).insert(1, :b).insert(2, :c).delete(1)
      peer2.receive_operations(peer1.flush_operations)
      expect(peer2.ordered_list.to_a).to eq [:a, :c]
    end

    it 'should order concurrent inserts at the same position deterministically' do
      peer1 = CRDT::Peer.new(:peer1)
      peer2 = CRDT::Peer.new(:peer2)
      peer1.ordered_list.insert(0, :a)
      peer2.receive_operations(peer1.flush_operations)
      peer2.ordered_list.insert(1, :b)
      peer1.ordered_list.insert(1, :c)
      peer1.receive_operations(peer2.flush_operations)
      peer2.receive_operations(peer1.flush_operations)
      expect(peer1.ordered_list.to_a).to eq [:a, :b, :c]
      expect(peer2.ordered_list.to_a).to eq [:a, :b, :c]
    end

    it 'should order concurrent inserts at the head deterministically' do
      peer1 = CRDT::Peer.new(:peer1)
      peer2 = CRDT::Peer.new(:peer2)
      peer2.ordered_list.insert(0, :a).insert(1, :b)
      peer1.ordered_list.insert(0, :c).insert(1, :d)
      peer2.receive_operations(peer1.flush_operations)
      peer1.receive_operations(peer2.flush_operations)
      expect(peer1.ordered_list.to_a).to eq [:a, :b, :c, :d]
      expect(peer2.ordered_list.to_a).to eq [:a, :b, :c, :d]
    end

    it 'should allow concurrent insertion and deletion at the same position' do
      peer1 = CRDT::Peer.new(:peer1)
      peer2 = CRDT::Peer.new(:peer2)
      peer1.ordered_list.insert(0, :a)
      peer2.receive_operations(peer1.flush_operations)
      peer1.ordered_list.delete(0)
      peer2.ordered_list.insert(1, :b)
      peer1.receive_operations(peer2.flush_operations)
      peer2.receive_operations(peer1.flush_operations)
      expect(peer1.ordered_list.to_a).to eq [:b]
      expect(peer2.ordered_list.to_a).to eq [:b]
    end

    it 'should not generate any further operations' do
      peer1 = CRDT::Peer.new(:peer1)
      peer2 = CRDT::Peer.new(:peer2)
      peer1.ordered_list.insert(0, :a)
      peer2.receive_operations(peer1.flush_operations)
      expect(peer2.flush_operations).to eq []
    end
  end
end

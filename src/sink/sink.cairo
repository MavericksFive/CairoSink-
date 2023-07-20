use starknet::ContractAddress;
use CairoSink::erc20::ERC20::{IERC20DispatcherTrait, IERC20Dispatcher};
use traits::{TryInto, Into};


#[derive(Copy, Drop, Serde, storage_access::StorageAccess)]
struct Stream {
    owner: ContractAddress,
    receiver: ContractAddress,
    amount: u256,
    start_time: u64,
    end_time: u64,
    token: IERC20Dispatcher,
    is_paused: bool
}


#[starknet::interface]
trait ISink<TContractState> {
    fn create_stream(
        ref self: TContractState,
        receiver: ContractAddress,
        amount: u256,
        end_time: u64,
        token: IERC20Dispatcher
    ) -> felt252;
    fn cancel_stream(ref self: TContractState, id: felt252);
    fn pause_stream(ref self: TContractState, id: felt252);
    fn unpause_stream(ref self: TContractState, id: felt252);
    fn withdraw(ref self: TContractState, id: felt252, amount: u256);
    fn get_id_counter(self: @TContractState) -> felt252;
    fn get_streams_counter(self: @TContractState) -> felt252;
    fn get_stream(self: @TContractState, id: felt252) -> Stream;
    fn get_time_when_stream_paused(self: @TContractState, id: felt252) -> u64;
    fn is_paused(self: @TContractState, id: felt252) -> bool;
    fn get_withdrawable_amount(self: @TContractState, id: felt252) -> u256;
}

#[starknet::contract]
mod Sink {
    use starknet::{
        ContractAddress, get_caller_address, get_block_timestamp, get_contract_address,
        contract_address_const
    };
    use super::{Stream, IERC20DispatcherTrait, IERC20Dispatcher};
    use CairoSink::ray_math::ray_math::RayMath;
    use CairoSink::ray_math::ray_math::RAY;
    use zeroable::{Zeroable};
    use traits::Into;


    #[storage]
    struct Storage {
        stream_counter: felt252,
        streams: LegacyMap::<felt252, Stream>,
        paused_streams: LegacyMap::<felt252, u64>
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        Created: Created,
        Cancelled: Cancelled,
        Withdrawn: Withdrawn
    }


    #[derive(Drop, starknet::Event)]
    struct Created {
        stream_id: felt252,
        #[key]
        owner: ContractAddress,
        #[key]
        receiver: ContractAddress,
        #[key]
        token: IERC20Dispatcher,
        amount: u256,
        end_time: u64,
    }

    #[derive(Drop, starknet::Event)]
    struct Cancelled {
        #[key]
        owner: ContractAddress,
        #[key]
        receiver: ContractAddress,
        amount: u256,
        stream_id: felt252,
    }

    #[derive(Drop, starknet::Event)]
    struct Withdrawn {
        #[key]
        user: ContractAddress,
        amount: u256
    }

    #[external(v0)]
    impl Sink of super::ISink<ContractState> {
        fn create_stream(
            ref self: ContractState,
            receiver: ContractAddress,
            amount: u256,
            end_time: u64,
            token: IERC20Dispatcher
        ) -> felt252 {
            assert(end_time > get_block_timestamp(), 'End time must be in the future');
            assert(receiver.is_non_zero(), 'Receiver cannot be zero');
            assert(amount.is_non_zero(), 'Amount cannot be zero');

            let stream_id = self.stream_counter.read() + 1;
            let start_time = get_block_timestamp();
            let owner = get_caller_address();
            let stream_data = Stream {
                amount: amount * RAY,
                start_time,
                end_time: end_time,
                receiver: receiver,
                owner: get_caller_address(),
                token: token,
                is_paused: false
            };
            self.streams.write(stream_id, stream_data);
            self.paused_streams.write(stream_id, 0_u64);
            self.stream_counter.write(stream_id);

            token.transferFrom(get_caller_address(), get_contract_address(), amount);
            self
                .emit(
                    Event::Created(Created { stream_id, owner, receiver, token, amount, end_time })
                );
            return stream_id;
        }


        fn withdraw(ref self: ContractState, id: felt252, amount: u256) {
            let mut stream = self._get_stream(id);
            let caller = get_caller_address();

            assert(caller == stream.owner || caller == stream.receiver, 'Unauthorized caller');

            let mut transfer_amount: u256 = 0;
            let ray_withdrawable_amount = self._ray_withdrawable_amount(id);
            let mut to: ContractAddress = contract_address_const::<0>();

            if (caller == stream.receiver) {
                assert(ray_withdrawable_amount >= amount * RAY, 'Withdraw amount too high');

                stream.amount -= ray_withdrawable_amount;
                stream.start_time = get_block_timestamp();
                transfer_amount = ray_withdrawable_amount / RAY;
                to = stream.receiver;
            } else {
                transfer_amount = (stream.amount - ray_withdrawable_amount) / RAY;

                assert(transfer_amount <= stream.amount, 'Wtihdraw amount too high');

                stream.amount -= amount * RAY;
                to = stream.owner;
            }

            self.streams.write(id, stream);
            stream.token.transfer(to, transfer_amount);

            self.emit(Event::Withdrawn(Withdrawn { user: caller, amount: transfer_amount }));
        }

        fn get_stream(self: @ContractState, id: felt252) -> Stream {
            return self.streams.read(id);
        }

        fn cancel_stream(ref self: ContractState, id: felt252) {
            let mut stream = self._get_stream(id);
            let caller = get_caller_address();
            assert((caller == stream.owner) | (caller == stream.receiver), 'NOT_AUTHORIZED');

            //InternalFunctions::_withdraw(ref self, id);
            stream.receiver = Zeroable::zero();
            stream.owner = Zeroable::zero();
            stream.amount = Zeroable::zero();
            stream.end_time = Zeroable::zero();

            self.streams.write(id, stream);

            self
                .emit(
                    Event::Cancelled(
                        Cancelled {
                            owner: stream.owner,
                            receiver: stream.receiver,
                            amount: stream.amount,
                            stream_id: id
                        }
                    )
                );
        }

        fn get_id_counter(self: @ContractState) -> felt252 {
            self.stream_counter.read()
        }

        fn get_time_when_stream_paused(self: @ContractState, id: felt252) -> u64 {
            return self.paused_streams.read(id);
        }

        fn is_paused(self: @ContractState, id: felt252) -> bool {
            return self.paused_streams.read(id) != 0_u64;
        }

        fn pause_stream(ref self: ContractState, id: felt252) {
            self._only_owner(id);
            assert(!Sink::is_paused(@self, id), 'Stream is already paused');
            let current_time = get_block_timestamp();
            self.paused_streams.write(id, current_time);
        }

        fn unpause_stream(ref self: ContractState, id: felt252) {
            self._only_owner(id);
            assert(Sink::is_paused(@self, id), 'Stream is already unpaused');
            self.paused_streams.write(id, 0_u64);
        }

        fn get_withdrawable_amount(self: @ContractState, id: felt252) -> u256 {
            return self._ray_withdrawable_amount(id) / RAY;
        }
        
        fn get_streams_counter(self: @ContractState) -> felt252 {
            return self.stream_counter.read();

        }
    }

    #[generate_trait]
    impl InternalFunctions of InternalFunctionsTrait {
        fn _get_stream(self: @ContractState, id: felt252) -> Stream {
            assert(InternalFunctions::_exists(self, id), 'STREAM_NOT_EXIST');
            self.streams.read(id)
        }

        fn _exists(self: @ContractState, id: felt252) -> bool {
            !self.streams.read(id).receiver.is_zero()
        }



        fn _only_owner(self: @ContractState, id: felt252) {
            assert(get_caller_address() == self.streams.read(id).owner, 'Unauthorized caller');
        }

        fn _only_receiver(self: @ContractState, id: felt252) {
            assert(get_caller_address() == self.streams.read(id).receiver, 'Unauthorized caller');
        }

        fn _ray_withdrawable_amount(self: @ContractState, id: felt252) -> u256 {
            let stream = self.streams.read(id);
            let block_timestamp = get_block_timestamp();
            let paused_timestamp = self.paused_streams.read(id);
            let mut time_elpased: u64 = 0;

            if (paused_timestamp > 0) {
                time_elpased = paused_timestamp - stream.start_time;
            } else if (block_timestamp < stream.end_time) {
                time_elpased = block_timestamp - stream.start_time;
            } else {
                return stream.amount;
            }

            let total_stream_time = stream.end_time - stream.start_time;

            return RayMath::ray_div(
                RayMath::ray_mul(time_elpased.into(), stream.amount), total_stream_time.into()
            );
        }
    }
}

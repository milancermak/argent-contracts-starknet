import os
from typing import Optional, List, Tuple
from starkware.starknet.testing.contract import StarknetContract
from starkware.starknet.testing.state import StarknetState
from starkware.starknet.business_logic.state.state import BlockInfo
from starkware.starknet.compiler.compile import compile_starknet_files
from starkware.starkware_utils.error_handling import StarkException
from starkware.starknet.definitions.error_codes import StarknetErrorCode
from starkware.starknet.business_logic.execution.objects import Event, TransactionExecutionInfo
from starkware.starknet.compiler.compile import get_selector_from_name
from starkware.starknet.services.api.contract_class import ContractClass

DEFAULT_TIMESTAMP = 1640991600

def str_to_felt(text: str) -> int:
    b_text = bytes(text, 'UTF-8')
    return int.from_bytes(b_text, "big")

def uint(a: int) -> Tuple[int, int]:
    return (a, 0)

async def assert_revert(expression, expected_message: Optional[str] = None, expected_code: Optional[StarknetErrorCode] = None):
    if expected_code is None:
        expected_code = StarknetErrorCode.TRANSACTION_FAILED
    try:
        await expression
        assert False
    except StarkException as err:
        _, error = err.args
        assert error['code'] == expected_code
        if expected_message is not None:
            assert expected_message in error['message']

def assert_event_emmited(tx_exec_info: TransactionExecutionInfo, from_address: int, name: str, data: Optional[List[int]] = []):
    if not data:
        raw_events = [Event(from_address=event.from_address, keys=event.keys, data=[]) for event in tx_exec_info.get_sorted_events()]
    else: 
        raw_events = [Event(from_address=event.from_address, keys=event.keys, data=event.data) for event in tx_exec_info.get_sorted_events()] 

    assert Event(
        from_address=from_address,
        keys=[get_selector_from_name(name)],
        data=data,
    ) in raw_events

def update_starknet_block(state: StarknetState, block_number=1, block_timestamp=DEFAULT_TIMESTAMP):
    state.state.block_info = BlockInfo(
        block_number=block_number,
        block_timestamp=block_timestamp,
        gas_price=0,
        starknet_version="0.9.1",
        sequencer_address=state.state.block_info.sequencer_address)

def reset_starknet_block(state: StarknetState):
    update_starknet_block(state=state)

def compile(path: str) -> ContractClass:
    contract_cls = compile_starknet_files([path], debug_info=True)
    return contract_cls

def cached_contract(state: StarknetState, _class: ContractClass, deployed: StarknetContract) -> StarknetContract:
    contract = StarknetContract(
        state=state,
        abi=_class.abi,
        contract_address=deployed.contract_address,
        deploy_call_info=deployed.deploy_call_info
    )
    return contract
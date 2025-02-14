import pytest
import asyncio
from starkware.starknet.testing.starknet import Starknet
from starkware.starknet.definitions.error_codes import StarknetErrorCode
from utils.Signer import Signer
from utils.utilities import compile, cached_contract, assert_revert, assert_event_emmited
from utils.TransactionSender import TransactionSender
from starkware.starknet.compiler.compile import get_selector_from_name

signer = Signer(1)
guardian = Signer(2)
wrong_signer = Signer(3)
wrong_guardian = Signer(4)

@pytest.fixture(scope='module')
def event_loop():
    return asyncio.new_event_loop()

@pytest.fixture(scope='module')
def contract_classes():
    proxy_cls = compile("contracts/upgrade/Proxy.cairo")
    account_cls = compile('contracts/account/ArgentAccount.cairo')
    dapp_cls = compile("contracts/test/TestDapp.cairo")
    
    return proxy_cls, account_cls, dapp_cls

@pytest.fixture(scope='module')
async def contract_init(contract_classes):
    proxy_cls, account_cls, dapp_cls = contract_classes
    starknet = await Starknet.empty()

    account_decl = await starknet.declare(contract_class=account_cls)
    account_2_decl = await starknet.declare(contract_class=account_cls)
    non_account_decl = await starknet.declare(contract_class=dapp_cls)

    proxy = await starknet.deploy(
        contract_class=proxy_cls,
        constructor_calldata=[account_decl.class_hash, get_selector_from_name('initialize'), 2, signer.public_key, guardian.public_key]
    )

    dapp = await starknet.deploy(
        contract_class=dapp_cls,
        constructor_calldata=[],
    )

    return starknet.state, proxy, dapp, account_decl.class_hash, account_2_decl.class_hash, non_account_decl.class_hash

@pytest.fixture
def contract_factory(contract_classes, contract_init):
    proxy_cls, implementation_cls, dapp_cls = contract_classes
    state, proxy, dapp, account_class, account_2_class, non_acccount_class = contract_init
    _state = state.copy()

    proxy = cached_contract(_state, proxy_cls, proxy)
    account = cached_contract(_state, implementation_cls, proxy)
    dapp = cached_contract(_state, dapp_cls, dapp)

    return proxy, account, dapp, account_class, account_2_class, non_acccount_class

@pytest.mark.asyncio
async def test_initializer(contract_factory):
    proxy, account, _, account_class, _, _ = contract_factory

    assert (await proxy.get_implementation().call()).result.implementation == account_class
    assert (await account.getSigner().call()).result.signer == signer.public_key
    assert (await account.getGuardian().call()).result.guardian == guardian.public_key

@pytest.mark.asyncio
async def test_call_dapp(contract_factory):
    _, account, dapp, _, _, _ = contract_factory
    sender = TransactionSender(account)

    # should revert with the wrong signer
    await assert_revert(
        sender.send_transaction([(dapp.contract_address, 'set_number', [47])], [wrong_signer, guardian]),
        "argent: signer signature invalid"
    )

    # should call the dapp
    assert (await dapp.get_number(account.contract_address).call()).result.number == 0
    await sender.send_transaction([(dapp.contract_address, 'set_number', [47])], [signer, guardian])
    assert (await dapp.get_number(account.contract_address).call()).result.number == 47

@pytest.mark.asyncio
async def test_upgrade(contract_factory):
    proxy, account, dapp, account_class, account_2_class, non_acccount_class = contract_factory
    sender = TransactionSender(account)

    # should revert with the wrong guardian
    await assert_revert(
        sender.send_transaction([(account.contract_address, 'upgrade', [account_2_class])], [signer, wrong_guardian]),
        "argent: guardian signature invalid"
    )

    # should revert when the target is not an account
    await assert_revert(
        sender.send_transaction([(account.contract_address, 'upgrade', [non_acccount_class])], [signer, guardian]),
        "argent: invalid implementation",
        StarknetErrorCode.ENTRY_POINT_NOT_FOUND_IN_CONTRACT
    )

    assert (await proxy.get_implementation().call()).result.implementation == (account_class)
    
    tx_exec_info = await sender.send_transaction([(account.contract_address, 'upgrade', [account_2_class])], [signer, guardian])
    
    assert_event_emmited(
        tx_exec_info,
        from_address=account.contract_address,
        name='account_upgraded',
        data=[account_2_class]
    )

    assert (await proxy.get_implementation().call()).result.implementation == (account_2_class)
    
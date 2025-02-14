%lang starknet

from starkware.cairo.common.cairo_builtins import HashBuiltin, SignatureBuiltin
from starkware.cairo.common.signature import verify_ecdsa_signature
from starkware.cairo.common.alloc import alloc
from starkware.cairo.common.memcpy import memcpy
from starkware.cairo.common.math import assert_not_zero, assert_le, assert_nn
from starkware.starknet.common.syscalls import (
    library_call,
    call_contract,
    get_tx_info,
    get_contract_address,
    get_caller_address,
    get_block_timestamp,
)
from starkware.cairo.common.bool import TRUE, FALSE

from contracts.upgrade.Upgradable import _set_implementation

const SUPPORTS_INTERFACE_SELECTOR = 1184015894760294494673613438913361435336722154500302038630992932234692784845;
const ERC165_ACCOUNT_INTERFACE_ID = 0xa66bd575;
const ERC165_ACCOUNT_INTERFACE_ID_OLD = 0xf10dbd44; // this is needed to upgrade to this version

/////////////////////
// STRUCTS
/////////////////////

struct Call {
    to: felt,
    selector: felt,
    calldata_len: felt,
    calldata: felt*,
}

// Tmp struct introduced while we wait for Cairo
// to support passing `[Call]` to __execute__
struct CallArray {
    to: felt,
    selector: felt,
    data_offset: felt,
    data_len: felt,
}

struct Escape {
    active_at: felt,
    type: felt,
}

/////////////////////
// EVENTS
/////////////////////

@event
func signer_changed(new_signer: felt) {
}

@event
func guardian_changed(new_guardian: felt) {
}

@event
func guardian_backup_changed(new_guardian: felt) {
}

@event
func escape_guardian_triggered(active_at: felt) {
}

@event
func escape_signer_triggered(active_at: felt) {
}

@event
func escape_canceled() {
}

@event
func guardian_escaped(new_guardian: felt) {
}

@event
func signer_escaped(new_signer: felt) {
}

@event
func account_upgraded(new_implementation: felt) {
}

/////////////////////
// STORAGE VARIABLES
/////////////////////

@storage_var
func _signer() -> (res: felt) {
}

@storage_var
func _guardian() -> (res: felt) {
}

@storage_var
func _guardian_backup() -> (res: felt) {
}

@storage_var
func _escape() -> (res: Escape) {
}

/////////////////////
// INTERNAL FUNCTIONS
/////////////////////

func assert_only_self{syscall_ptr: felt*}() -> () {
    let (self) = get_contract_address();
    let (caller_address) = get_caller_address();
    with_attr error_message("argent: only self") {
        assert self = caller_address;
    }
    return ();
}

func assert_initialized{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() {
    let (signer) = _signer.read();
    with_attr error_message("argent: account not initialized") {
        assert_not_zero(signer);
    }
    return ();
}

func assert_non_reentrant{syscall_ptr: felt*}() -> () {
    let (caller) = get_caller_address();
    with_attr error_message("argent: no reentrant call") {
        assert caller = 0;
    }
    return ();
}

func assert_correct_version{syscall_ptr: felt*}(version: felt) -> () {
    with_attr error_message("argent: invalid tx version") {
        assert version = 1;
    }
    return ();
}

func assert_guardian_set{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() {
    let (guardian) = _guardian.read();
    with_attr error_message("argent: guardian required") {
        assert_not_zero(guardian);
    }
    return ();
}

func assert_no_self_call(self: felt, call_array_len: felt, call_array: CallArray*) {
    if (call_array_len == 0) {
        return ();
    }
    assert_not_zero(call_array[0].to - self);
    assert_no_self_call(self, call_array_len - 1, call_array + CallArray.SIZE);
    return ();
}

// @notice Executes a list of contract calls recursively.
// @param calls_len The number of calls to execute
// @param calls A pointer to the first call to execute
// @param response The array of felt to pupulate with the returned data
// @return response_len The size of the returned data
func execute_calls{syscall_ptr: felt*}(calls_len: felt, calls: Call*, reponse: felt*, index: felt) -> (
    response_len: felt
) {
    alloc_locals;

    // if no more calls
    if (calls_len == 0) {
        return (0,);
    }

    // do the current call
    let this_call: Call = [calls];
    with_attr error_message("argent: multicall {index} failed") {
        let res = call_contract(
            contract_address=this_call.to,
            function_selector=this_call.selector,
            calldata_size=this_call.calldata_len,
            calldata=this_call.calldata,
        );
    }
    // copy the result in response
    memcpy(reponse, res.retdata, res.retdata_size);
    // do the next calls recursively
    let (response_len) = execute_calls(calls_len - 1, calls + Call.SIZE, reponse + res.retdata_size, index + 1);
    return (response_len + res.retdata_size,);
}

func from_call_array_to_call{syscall_ptr: felt*}(
    call_array_len: felt, call_array: CallArray*, calldata: felt*, calls: Call*
) {
    // if no more calls
    if (call_array_len == 0) {
        return ();
    }

    // parse the current call
    assert [calls] = Call(
        to=[call_array].to,
        selector=[call_array].selector,
        calldata_len=[call_array].data_len,
        calldata=calldata + [call_array].data_offset
        );

    // parse the remaining calls recursively
    from_call_array_to_call(
        call_array_len - 1, call_array + CallArray.SIZE, calldata, calls + Call.SIZE
    );
    return ();
}

namespace ArgentModel {

    const CHANGE_SIGNER_SELECTOR = 174572128530328568741270994650351248940644050288235239638974755381225723145;
    const CHANGE_GUARDIAN_SELECTOR = 1296071702357547150019664216025682391016361613613945351022196390148584441374;
    const TRIGGER_ESCAPE_GUARDIAN_SELECTOR = 145954635736934016296422259475449005649670140213177066015821444644082814628;
    const TRIGGER_ESCAPE_SIGNER_SELECTOR = 440853473255486090032829492468113410146539319637824817002531798290796877036;
    const ESCAPE_GUARDIAN_SELECTOR = 510756951529079116816142749077704776910668567546043821008232923043034641617;
    const ESCAPE_SIGNER_SELECTOR = 1455116469465411075152303383382102930902943882042348163899277328605146981359;
    const CANCEL_ESCAPE_SELECTOR = 1387988583969094862956788899343599960070518480842441785602446058600435897039;

    const ESCAPE_SECURITY_PERIOD = 7 * 24 * 60 * 60;  // 7 days

    const ESCAPE_TYPE_GUARDIAN = 1;
    const ESCAPE_TYPE_SIGNER = 2;

    /////////////////////
    // WRITE FUNCTIONS
    /////////////////////

    func initialize{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
        signer: felt, guardian: felt
    ) {
        // check that we are not already initialized
        let (current_signer) = _signer.read();
        with_attr error_message("argent: already initialized") {
            assert current_signer = 0;
        }
        // check that the target signer is not zero
        with_attr error_message("argent: signer cannot be null") {
            assert_not_zero(signer);
        }
        // initialize the contract
        _signer.write(signer);
        _guardian.write(guardian);
        return ();
    }

    func upgrade{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
        implementation: felt
    ) {
        // only called via execute
        assert_only_self();
        // make sure the target is an account
        with_attr error_message("argent: invalid implementation") {
            let (calldata: felt*) = alloc();
            assert calldata[0] = ERC165_ACCOUNT_INTERFACE_ID;
            let (retdata_size: felt, retdata: felt*) = library_call(
                class_hash=implementation,
                function_selector=SUPPORTS_INTERFACE_SELECTOR,
                calldata_size=1,
                calldata=calldata,
            );
            assert retdata_size = 1;
            assert [retdata] = TRUE;
        }
        // change implementation
        _set_implementation(implementation);
        account_upgraded.emit(new_implementation=implementation);
        return ();
    }

    func change_signer{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
        new_signer: felt
    ) {
        // only called via execute
        assert_only_self();

        // change signer
        with_attr error_message("argent: signer cannot be null") {
            assert_not_zero(new_signer);
        }
        _signer.write(new_signer);
        signer_changed.emit(new_signer=new_signer);
        return ();
    }

    func change_guardian{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
        new_guardian: felt
    ) {
        alloc_locals;

        // only called via execute
        assert_only_self();

        // make sure guardian_backup = 0 when new_guardian = 0
        let (guardian_backup) = _guardian_backup.read();
        if (new_guardian == 0) {
            with_attr error_message("argent: new guardian invalid") {
                assert guardian_backup = 0;
            }
        }

        // change guardian
        _guardian.write(new_guardian);
        guardian_changed.emit(new_guardian=new_guardian);
        return ();
    }

    func change_guardian_backup{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
        new_guardian: felt
    ) {
        // only called via execute
        assert_only_self();

        // no backup when there is no guardian set
        assert_guardian_set();

        // change guardian
        _guardian_backup.write(new_guardian);
        guardian_backup_changed.emit(new_guardian=new_guardian);
        return ();
    }

    func trigger_escape_guardian{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() {
        // only called via execute
        assert_only_self();

        // no escape when the guardian is not set
        assert_guardian_set();

        // store new escape
        let (block_timestamp) = get_block_timestamp();
        let new_escape: Escape = Escape(block_timestamp + ESCAPE_SECURITY_PERIOD, ESCAPE_TYPE_GUARDIAN);
        _escape.write(new_escape);
        escape_guardian_triggered.emit(active_at=block_timestamp + ESCAPE_SECURITY_PERIOD);
        return ();
    }

    func trigger_escape_signer{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() {
        // only called via execute
        assert_only_self();

        // no escape when there is no guardian set
        assert_guardian_set();

        // no escape if there is an guardian escape triggered by the signer in progress
        let (current_escape) = _escape.read();
        with_attr error_message("argent: cannot override escape") {
            assert current_escape.active_at * (current_escape.type - ESCAPE_TYPE_SIGNER) = 0;
        }

        // store new escape
        let (block_timestamp) = get_block_timestamp();
        let new_escape: Escape = Escape(block_timestamp + ESCAPE_SECURITY_PERIOD, ESCAPE_TYPE_SIGNER);
        _escape.write(new_escape);
        escape_signer_triggered.emit(active_at=block_timestamp + ESCAPE_SECURITY_PERIOD);
        return ();
    }

    func cancel_escape{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() {
        // only called via execute
        assert_only_self();

        // validate there is an active escape
        let (current_escape) = _escape.read();
        with_attr error_message("argent: no active escape") {
            assert_not_zero(current_escape.active_at);
        }

        // clear escape
        let new_escape: Escape = Escape(0, 0);
        _escape.write(new_escape);
        escape_canceled.emit();
        return ();
    }

    func escape_guardian{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
        new_guardian: felt
    ) {
        alloc_locals;

        // only called via execute
        assert_only_self();
        // no escape when the guardian is not set
        assert_guardian_set();

        let (current_escape) = _escape.read();
        let (block_timestamp) = get_block_timestamp();
        with_attr error_message("argent: not escaping") {
            assert_not_zero(current_escape.active_at);
        }
        with_attr error_message("argent: escape not active") {
            assert_le(current_escape.active_at, block_timestamp);
        }
        with_attr error_message("argent: escape type invalid") {
            assert current_escape.type = ESCAPE_TYPE_GUARDIAN;
        }

        // clear escape
        let new_escape: Escape = Escape(0, 0);
        _escape.write(new_escape);

        // change guardian
        assert_not_zero(new_guardian);
        _guardian.write(new_guardian);
        guardian_escaped.emit(new_guardian=new_guardian);

        return ();
    }

    func escape_signer{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
        new_signer: felt
    ) {
        alloc_locals;

        // only called via execute
        assert_only_self();
        // no escape when the guardian is not set
        assert_guardian_set();

        let (current_escape) = _escape.read();
        let (block_timestamp) = get_block_timestamp();
        with_attr error_message("argent: not escaping") {
            assert_not_zero(current_escape.active_at);
        }
        with_attr error_message("argent: escape not active") {
            assert_le(current_escape.active_at, block_timestamp);
        }
        with_attr error_message("argent: escape type invalid") {
            assert current_escape.type = ESCAPE_TYPE_SIGNER;
        }

        // clear escape
        let new_escape: Escape = Escape(0, 0);
        _escape.write(new_escape);

        // change signer
        assert_not_zero(new_signer);
        _signer.write(new_signer);
        signer_escaped.emit(new_signer=new_signer);

        return ();
    }

    /////////////////////
    // VIEW FUNCTIONS
    /////////////////////

    func is_valid_signature{
        syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, ecdsa_ptr: SignatureBuiltin*, range_check_ptr
    }(hash: felt, sig_len: felt, sig: felt*) -> (is_valid: felt) {
        alloc_locals;

        let (is_signer_sig_valid) = validate_signer_signature(hash, sig_len, sig);
        let (is_guardian_sig_valid) = validate_guardian_signature(hash, sig_len - 2, sig + 2);

        // Cairo's way of doing `&&` is by multiplying the two booleans.
        return (is_valid=is_signer_sig_valid * is_guardian_sig_valid);
    }

    func supports_interface{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
        interface_id: felt
    ) -> (success: felt) {
        // 165
        if (interface_id == 0x01ffc9a7) {
            return (TRUE,);
        }
        // IAccount
        if (interface_id == ERC165_ACCOUNT_INTERFACE_ID) {
            return (TRUE,);
        }
        // Old IAccount
        if (interface_id == ERC165_ACCOUNT_INTERFACE_ID_OLD) {
            return (TRUE,);
        }
        return (FALSE,);
    }

    func get_signer{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() -> (
        signer: felt
    ) {
        let (res) = _signer.read();
        return (signer=res);
    }

    func get_guardian{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() -> (
        guardian: felt
    ) {
        let (res) = _guardian.read();
        return (guardian=res);
    }

    func get_guardian_backup{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() -> (
        guardian_backup: felt
    ) {
        let (res) = _guardian_backup.read();
        return (guardian_backup=res);
    }

    func get_escape{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() -> (
        active_at: felt, type: felt
    ) {
        let (res) = _escape.read();
        return (active_at=res.active_at, type=res.type);
    }

    func validate_signer_signature{
        syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, ecdsa_ptr: SignatureBuiltin*, range_check_ptr
    }(message: felt, signatures_len: felt, signatures: felt*) -> (is_valid: felt) {
        with_attr error_message("argent: signer signature invalid") {
            assert_nn(signatures_len - 2);
            let (signer) = _signer.read();
            verify_ecdsa_signature(
                message=message, public_key=signer, signature_r=signatures[0], signature_s=signatures[1]
            );
        }
        return (is_valid=TRUE);
    }

    func validate_guardian_signature{
        syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, ecdsa_ptr: SignatureBuiltin*, range_check_ptr
    }(message: felt, signatures_len: felt, signatures: felt*) -> (is_valid: felt) {
        alloc_locals;
        
        let (guardian) = _guardian.read();
        if (guardian == 0) {
            return (is_valid=TRUE);
        }

        if (signatures_len == 2) {
            with_attr error_message("argent: guardian signature invalid") {
                verify_ecdsa_signature(
                    message=message,
                    public_key=guardian,
                    signature_r=signatures[0],
                    signature_s=signatures[1],
                );
            }
            return (is_valid=TRUE);
        }
        
        let (guardian_backup) = _guardian_backup.read();
        with_attr error_message("argent: signature format invalid") {
            assert signatures_len = 4;
            assert (signatures[0] + signatures[1]) = 0;
        }
         with_attr error_message("argent: guardian backup signature invalid") {
            verify_ecdsa_signature(
                message=message,
                public_key=guardian_backup,
                signature_r=signatures[2],
                signature_s=signatures[3],
            );
        }
        return (is_valid=TRUE);
    }
}

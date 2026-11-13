//! SQLSTATE codes: the five-byte code a PostgreSQL error carries.
//!
//! The code is the enum tag. Five ASCII bytes pack into a `u40` big-endian, so
//! a named code and a code this table does not name are the same kind of value
//! and cost the same to compare, switch on, or print. `format` rebuilds the
//! five bytes from the tag, so an unknown code logs as itself rather than as a
//! number.
//!
//! The variants are the condition names the standard gives, in the order
//! Appendix A lists them, with a comment per class. The set is open: the enum
//! is non-exhaustive because any five ASCII bytes are a legal code, an
//! extension can define more, and a client must not panic on one it has not
//! heard of. Five condition names are used by more than one class; the later
//! one carries its class as a suffix, as in `null_value_not_allowed_39`.
//!
//! Generated from https://www.postgresql.org/docs/current/errcodes-appendix.html
//!
//! ```text
//! if (field.state()) |state| switch (state) {
//!     .unique_violation => ...,
//!     else => ...,
//! };
//! ```

const std = @import("std");
const testing = std.testing;
const Io = std.Io;

const readInt = @import("mem.zig").readInt;
const wire = @import("wire.zig");
const writeInt = @import("mem.zig").writeInt;

/// A code as a value: the five ASCII bytes packed big-endian into forty bits.
///
/// The number is the code, so a packed code compares, switches, and tags the
/// enum without a table. The bytes are how it travels, and that belongs to the
/// reader and the writer: `stdx.wire.Reader` reads a `SqlState` straight off
/// five bytes because the tag type is an integer.
pub const Code = u40;

/// The bytes a code occupies on the wire.
pub const Wire = [len]u8;

/// Pack a code's bytes into its value. The first byte is the high byte, which
/// is also the order the reader hands them over in.
/// ziglint-ignore: Z012
pub fn pack(code: *const Wire) Code {
    return readInt(u40, code);
}

/// The length of a SQLSTATE code, in bytes.
pub const len = 5;

pub const SqlState = enum(Code) {
    /// A code as it appears on the wire, which is also its position in this
    /// list.
    // Class 00 — Successful Completion
    successful_completion = pack("00000"),

    // Class 01 — Warning
    warning = pack("01000"),
    dynamic_result_sets_returned = pack("0100C"),
    implicit_zero_bit_padding = pack("01008"),
    null_value_eliminated_in_set_function = pack("01003"),
    privilege_not_granted = pack("01007"),
    privilege_not_revoked = pack("01006"),
    string_data_right_truncation = pack("01004"),
    deprecated_feature = pack("01P01"),

    // Class 02 — No Data (this is also a warning class per the SQL standard)
    no_data = pack("02000"),
    no_additional_dynamic_result_sets_returned = pack("02001"),

    // Class 03 — SQL Statement Not Yet Complete
    sql_statement_not_yet_complete = pack("03000"),

    // Class 08 — Connection Exception
    connection_exception = pack("08000"),
    connection_does_not_exist = pack("08003"),
    connection_failure = pack("08006"),
    sqlclient_unable_to_establish_sqlconnection = pack("08001"),
    sqlserver_rejected_establishment_of_sqlconnection = pack("08004"),
    transaction_resolution_unknown = pack("08007"),
    protocol_violation = pack("08P01"),

    // Class 09 — Triggered Action Exception
    triggered_action_exception = pack("09000"),

    // Class 0A — Feature Not Supported
    feature_not_supported = pack("0A000"),

    // Class 0B — Invalid Transaction Initiation
    invalid_transaction_initiation = pack("0B000"),

    // Class 0F — Locator Exception
    locator_exception = pack("0F000"),
    invalid_locator_specification = pack("0F001"),

    // Class 0L — Invalid Grantor
    invalid_grantor = pack("0L000"),
    invalid_grant_operation = pack("0LP01"),

    // Class 0P — Invalid Role Specification
    invalid_role_specification = pack("0P000"),

    // Class 0Z — Diagnostics Exception
    diagnostics_exception = pack("0Z000"),
    stacked_diagnostics_accessed_without_active_handler = pack("0Z002"),

    // Class 10 — XQuery Error
    invalid_argument_for_xquery = pack("10608"),

    // Class 20 — Case Not Found
    case_not_found = pack("20000"),

    // Class 21 — Cardinality Violation
    cardinality_violation = pack("21000"),

    // Class 22 — Data Exception
    data_exception = pack("22000"),
    array_subscript_error = pack("2202E"),
    character_not_in_repertoire = pack("22021"),
    datetime_field_overflow = pack("22008"),
    division_by_zero = pack("22012"),
    error_in_assignment = pack("22005"),
    escape_character_conflict = pack("2200B"),
    indicator_overflow = pack("22022"),
    interval_field_overflow = pack("22015"),
    invalid_argument_for_logarithm = pack("2201E"),
    invalid_argument_for_ntile_function = pack("22014"),
    invalid_argument_for_nth_value_function = pack("22016"),
    invalid_argument_for_power_function = pack("2201F"),
    invalid_argument_for_width_bucket_function = pack("2201G"),
    invalid_character_value_for_cast = pack("22018"),
    invalid_datetime_format = pack("22007"),
    invalid_escape_character = pack("22019"),
    invalid_escape_octet = pack("2200D"),
    invalid_escape_sequence = pack("22025"),
    nonstandard_use_of_escape_character = pack("22P06"),
    invalid_indicator_parameter_value = pack("22010"),
    invalid_parameter_value = pack("22023"),
    invalid_preceding_or_following_size = pack("22013"),
    invalid_regular_expression = pack("2201B"),
    invalid_row_count_in_limit_clause = pack("2201W"),
    invalid_row_count_in_result_offset_clause = pack("2201X"),
    invalid_tablesample_argument = pack("2202H"),
    invalid_tablesample_repeat = pack("2202G"),
    invalid_time_zone_displacement_value = pack("22009"),
    invalid_use_of_escape_character = pack("2200C"),
    most_specific_type_mismatch = pack("2200G"),
    null_value_not_allowed = pack("22004"),
    null_value_no_indicator_parameter = pack("22002"),
    numeric_value_out_of_range = pack("22003"),
    sequence_generator_limit_exceeded = pack("2200H"),
    string_data_length_mismatch = pack("22026"),
    string_data_right_truncation_22 = pack("22001"),
    substring_error = pack("22011"),
    trim_error = pack("22027"),
    unterminated_c_string = pack("22024"),
    zero_length_character_string = pack("2200F"),
    floating_point_exception = pack("22P01"),
    invalid_text_representation = pack("22P02"),
    invalid_binary_representation = pack("22P03"),
    bad_copy_file_format = pack("22P04"),
    untranslatable_character = pack("22P05"),
    datum_version_mismatch = pack("22P07"),
    not_an_xml_document = pack("2200L"),
    invalid_xml_document = pack("2200M"),
    invalid_xml_content = pack("2200N"),
    invalid_xml_comment = pack("2200S"),
    invalid_xml_processing_instruction = pack("2200T"),
    duplicate_json_object_key_value = pack("22030"),
    invalid_argument_for_sql_json_datetime_function = pack("22031"),
    invalid_json_text = pack("22032"),
    invalid_sql_json_subscript = pack("22033"),
    more_than_one_sql_json_item = pack("22034"),
    no_sql_json_item = pack("22035"),
    non_numeric_sql_json_item = pack("22036"),
    non_unique_keys_in_a_json_object = pack("22037"),
    singleton_sql_json_item_required = pack("22038"),
    sql_json_array_not_found = pack("22039"),
    sql_json_member_not_found = pack("2203A"),
    sql_json_number_not_found = pack("2203B"),
    sql_json_object_not_found = pack("2203C"),
    too_many_json_array_elements = pack("2203D"),
    too_many_json_object_members = pack("2203E"),
    sql_json_scalar_required = pack("2203F"),
    sql_json_item_cannot_be_cast_to_target_type = pack("2203G"),

    // Class 23 — Integrity Constraint Violation
    integrity_constraint_violation = pack("23000"),
    restrict_violation = pack("23001"),
    not_null_violation = pack("23502"),
    foreign_key_violation = pack("23503"),
    unique_violation = pack("23505"),
    check_violation = pack("23514"),
    exclusion_violation = pack("23P01"),

    // Class 24 — Invalid Cursor State
    invalid_cursor_state = pack("24000"),

    // Class 25 — Invalid Transaction State
    invalid_transaction_state = pack("25000"),
    active_sql_transaction = pack("25001"),
    branch_transaction_already_active = pack("25002"),
    held_cursor_requires_same_isolation_level = pack("25008"),
    inappropriate_access_mode_for_branch_transaction = pack("25003"),
    inappropriate_isolation_level_for_branch_transaction = pack("25004"),
    no_active_sql_transaction_for_branch_transaction = pack("25005"),
    read_only_sql_transaction = pack("25006"),
    schema_and_data_statement_mixing_not_supported = pack("25007"),
    no_active_sql_transaction = pack("25P01"),
    in_failed_sql_transaction = pack("25P02"),
    idle_in_transaction_session_timeout = pack("25P03"),
    transaction_timeout = pack("25P04"),

    // Class 26 — Invalid SQL Statement Name
    invalid_sql_statement_name = pack("26000"),

    // Class 27 — Triggered Data Change Violation
    triggered_data_change_violation = pack("27000"),

    // Class 28 — Invalid Authorization Specification
    invalid_authorization_specification = pack("28000"),
    invalid_password = pack("28P01"),

    // Class 2B — Dependent Privilege Descriptors Still Exist
    dependent_privilege_descriptors_still_exist = pack("2B000"),
    dependent_objects_still_exist = pack("2BP01"),

    // Class 2D — Invalid Transaction Termination
    invalid_transaction_termination = pack("2D000"),

    // Class 2F — SQL Routine Exception
    sql_routine_exception = pack("2F000"),
    function_executed_no_return_statement = pack("2F005"),
    modifying_sql_data_not_permitted = pack("2F002"),
    prohibited_sql_statement_attempted = pack("2F003"),
    reading_sql_data_not_permitted = pack("2F004"),

    // Class 34 — Invalid Cursor Name
    invalid_cursor_name = pack("34000"),

    // Class 38 — External Routine Exception
    external_routine_exception = pack("38000"),
    containing_sql_not_permitted = pack("38001"),
    modifying_sql_data_not_permitted_38 = pack("38002"),
    prohibited_sql_statement_attempted_38 = pack("38003"),
    reading_sql_data_not_permitted_38 = pack("38004"),

    // Class 39 — External Routine Invocation Exception
    external_routine_invocation_exception = pack("39000"),
    invalid_sqlstate_returned = pack("39001"),
    null_value_not_allowed_39 = pack("39004"),
    trigger_protocol_violated = pack("39P01"),
    srf_protocol_violated = pack("39P02"),
    event_trigger_protocol_violated = pack("39P03"),

    // Class 3B — Savepoint Exception
    savepoint_exception = pack("3B000"),
    invalid_savepoint_specification = pack("3B001"),

    // Class 3D — Invalid Catalog Name
    invalid_catalog_name = pack("3D000"),

    // Class 3F — Invalid Schema Name
    invalid_schema_name = pack("3F000"),

    // Class 40 — Transaction Rollback
    transaction_rollback = pack("40000"),
    transaction_integrity_constraint_violation = pack("40002"),
    serialization_failure = pack("40001"),
    statement_completion_unknown = pack("40003"),
    deadlock_detected = pack("40P01"),

    // Class 42 — Syntax Error or Access Rule Violation
    syntax_error_or_access_rule_violation = pack("42000"),
    syntax_error = pack("42601"),
    insufficient_privilege = pack("42501"),
    cannot_coerce = pack("42846"),
    grouping_error = pack("42803"),
    windowing_error = pack("42P20"),
    invalid_recursion = pack("42P19"),
    invalid_foreign_key = pack("42830"),
    invalid_name = pack("42602"),
    name_too_long = pack("42622"),
    reserved_name = pack("42939"),
    datatype_mismatch = pack("42804"),
    indeterminate_datatype = pack("42P18"),
    collation_mismatch = pack("42P21"),
    indeterminate_collation = pack("42P22"),
    wrong_object_type = pack("42809"),
    generated_always = pack("428C9"),
    undefined_column = pack("42703"),
    undefined_function = pack("42883"),
    undefined_table = pack("42P01"),
    undefined_parameter = pack("42P02"),
    undefined_object = pack("42704"),
    duplicate_column = pack("42701"),
    duplicate_cursor = pack("42P03"),
    duplicate_database = pack("42P04"),
    duplicate_function = pack("42723"),
    duplicate_prepared_statement = pack("42P05"),
    duplicate_schema = pack("42P06"),
    duplicate_table = pack("42P07"),
    duplicate_alias = pack("42712"),
    duplicate_object = pack("42710"),
    ambiguous_column = pack("42702"),
    ambiguous_function = pack("42725"),
    ambiguous_parameter = pack("42P08"),
    ambiguous_alias = pack("42P09"),
    invalid_column_reference = pack("42P10"),
    invalid_column_definition = pack("42611"),
    invalid_cursor_definition = pack("42P11"),
    invalid_database_definition = pack("42P12"),
    invalid_function_definition = pack("42P13"),
    invalid_prepared_statement_definition = pack("42P14"),
    invalid_schema_definition = pack("42P15"),
    invalid_table_definition = pack("42P16"),
    invalid_object_definition = pack("42P17"),

    // Class 44 — WITH CHECK OPTION Violation
    with_check_option_violation = pack("44000"),

    // Class 53 — Insufficient Resources
    insufficient_resources = pack("53000"),
    disk_full = pack("53100"),
    out_of_memory = pack("53200"),
    too_many_connections = pack("53300"),
    configuration_limit_exceeded = pack("53400"),

    // Class 54 — Program Limit Exceeded
    program_limit_exceeded = pack("54000"),
    statement_too_complex = pack("54001"),
    too_many_columns = pack("54011"),
    too_many_arguments = pack("54023"),

    // Class 55 — Object Not In Prerequisite State
    object_not_in_prerequisite_state = pack("55000"),
    object_in_use = pack("55006"),
    cant_change_runtime_param = pack("55P02"),
    lock_not_available = pack("55P03"),
    unsafe_new_enum_value_usage = pack("55P04"),

    // Class 57 — Operator Intervention
    operator_intervention = pack("57000"),
    query_canceled = pack("57014"),
    admin_shutdown = pack("57P01"),
    crash_shutdown = pack("57P02"),
    cannot_connect_now = pack("57P03"),
    database_dropped = pack("57P04"),
    idle_session_timeout = pack("57P05"),
    system_error = pack("58000"),
    io_error = pack("58030"),
    undefined_file = pack("58P01"),
    duplicate_file = pack("58P02"),
    file_name_too_long = pack("58P03"),

    // Class F0 — Configuration File Error
    config_file_error = pack("F0000"),
    lock_file_exists = pack("F0001"),

    // Class HV — Foreign Data Wrapper Error (SQL/MED)
    fdw_error = pack("HV000"),
    fdw_column_name_not_found = pack("HV005"),
    fdw_dynamic_parameter_value_needed = pack("HV002"),
    fdw_function_sequence_error = pack("HV010"),
    fdw_inconsistent_descriptor_information = pack("HV021"),
    fdw_invalid_attribute_value = pack("HV024"),
    fdw_invalid_column_name = pack("HV007"),
    fdw_invalid_column_number = pack("HV008"),
    fdw_invalid_data_type = pack("HV004"),
    fdw_invalid_data_type_descriptors = pack("HV006"),
    fdw_invalid_descriptor_field_identifier = pack("HV091"),
    fdw_invalid_handle = pack("HV00B"),
    fdw_invalid_option_index = pack("HV00C"),
    fdw_invalid_option_name = pack("HV00D"),
    fdw_invalid_string_length_or_buffer_length = pack("HV090"),
    fdw_invalid_string_format = pack("HV00A"),
    fdw_invalid_use_of_null_pointer = pack("HV009"),
    fdw_too_many_handles = pack("HV014"),
    fdw_out_of_memory = pack("HV001"),
    fdw_no_schemas = pack("HV00P"),
    fdw_option_name_not_found = pack("HV00J"),
    fdw_reply_handle = pack("HV00K"),
    fdw_schema_not_found = pack("HV00Q"),
    fdw_table_not_found = pack("HV00R"),
    fdw_unable_to_create_execution = pack("HV00L"),
    fdw_unable_to_create_reply = pack("HV00M"),
    fdw_unable_to_establish_connection = pack("HV00N"),

    // Class P0 — PL/pgSQL Error
    plpgsql_error = pack("P0000"),
    raise_exception = pack("P0001"),
    no_data_found = pack("P0002"),
    too_many_rows = pack("P0003"),
    assert_failure = pack("P0004"),

    // Class XX — Internal Error
    internal_error = pack("XX000"),
    data_corrupted = pack("XX001"),
    index_corrupted = pack("XX002"),

    /// A code this table does not name. The set is open and any five ASCII
    /// bytes are legal, so this is reachable in normal operation rather than a
    /// broken invariant.
    _,

    /// The bytes this code occupies on the wire.
    pub fn code(self: SqlState) Wire {
        var bytes: Wire = undefined;
        writeInt(u40, &bytes, @backingInt(self));
        return bytes;
    }

    /// A code from the bytes a message carried, named or not.
    pub fn fromBytes(bytes: *const Wire) SqlState {
        return @fromBackingInt(pack(bytes));
    }

    /// A code from a slice, or null when the length is wrong.
    pub fn fromSlice(bytes: []const u8) ?SqlState {
        if (bytes.len != len) return null;
        return .fromBytes(bytes[0..len]);
    }

    pub fn format(self: SqlState, writer: *Io.Writer) Io.Writer.Error!void {
        try writer.writeAll(&self.code());
    }
};

test "a code round-trips through its tag" {
    try testing.expectEqualStrings("42P01", &SqlState.undefined_table.code());
    try testing.expectEqualStrings("00000", &SqlState.successful_completion.code());
    try testing.expectEqual(SqlState.undefined_table, SqlState.fromBytes("42P01"));
    try testing.expectEqual(SqlState.undefined_table, SqlState.fromSlice("42P01").?);
    try testing.expectEqual(@as(?SqlState, null), SqlState.fromSlice("42P0"));
}

test "a code this table does not name keeps its bytes" {
    // Any five ASCII bytes are a legal code, and a client has to carry one it
    // has no variant for.
    const unknown = SqlState.fromBytes("ZZ999");
    try testing.expectEqualStrings("ZZ999", &unknown.code());
    try testing.expectFmt("ZZ999", "{f}", .{unknown});
}

test "the reader reads a state off five bytes" {
    // The value is the code, so the wire form is the reader's business and
    // there is nothing to convert first.
    var reader: wire.Reader = .init("23505");
    try testing.expectEqual(SqlState.unique_violation, try reader.read(SqlState));
    try testing.expectEqual(@as(usize, 0), reader.remaining().len);
}

test "the named codes print as themselves" {
    try testing.expectFmt("23505", "{f}", .{SqlState.unique_violation});
}

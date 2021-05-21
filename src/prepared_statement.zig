const std = @import("std");
const Allocator = std.mem.Allocator;

const odbc = @import("odbc");

const ResultSet = @import("result_set.zig").ResultSet;
const FetchResult = @import("result_set.zig").FetchResult;
const BindType = @import("result_set.zig").BindType;

const EraseComptime = @import("util.zig").EraseComptime;
const sql_parameter = @import("parameter.zig");

fn getBindType(comptime T: type) BindType {
    return if (@hasDecl(T, "fromRow")) .column else .row;
}

/// A prepared statement is created by submitting a SQL statement prior to execution. This allows the statement
/// to be executed multiple times without having to re-prepare the query.
pub const PreparedStatement = struct {
    statement: odbc.Statement,
    num_params: usize,
    param_data: std.ArrayListUnmanaged(u8),
    param_indicators: []c_longlong,

    allocator: *Allocator,

    pub fn init(allocator: *Allocator, statement: odbc.Statement, num_params: usize) !PreparedStatement {
        return PreparedStatement{
            .statement = statement,
            .num_params = num_params,
            .param_data = try std.ArrayListUnmanaged(u8).initCapacity(allocator, num_params * 8),
            .param_indicators = try allocator.alloc(c_longlong, num_params),
            .allocator = allocator
        };
    }

    /// Free allocated memory, close any open cursors, and deinitialize the statement. The underlying statement
    /// will become invalidated after calling this function.
    pub fn deinit(self: *PreparedStatement) void {
        self.param_data.deinit(self.allocator);
        self.allocator.free(self.param_indicators);
        self.close() catch |_| {};
        self.statement.deinit() catch |_| {};
    }

    pub fn execute(self: *PreparedStatement) !void {
        _ = try self.statement.execute();
    }

    /// Execute the current statement, binding the result columns to the fields of the type `Result`.
    /// Returns a ResultSet from which each row can be retrieved.
    pub fn fetch(self: *PreparedStatement, comptime Result: type) !ResultSet(Result, getBindType(Result)) {
        const RowType = FetchResult(Result);

        try self.execute();

        const bind_type = comptime getBindType(Result);
        const size = switch (bind_type) {
            .row => 10,
            .column => try self.statement.numResultColumns()
        };

        var result_set = try ResultSet(Result, bind_type).init(self.allocator, &self.statement, size);
        errdefer result_set.deinit();

        if (bind_type == .row) {
            try self.statement.setAttribute(.{ .RowBindType = @sizeOf(RowType) });
            try self.statement.setAttribute(.{ .RowArraySize = size });
            try self.statement.setAttribute(.{ .RowStatusPointer = result_set.row_status });
            try self.statement.setAttribute(.{ .RowsFetchedPointer = &result_set.rows_fetched });
        }

        self.statement.fetch() catch |err| switch (err) {
            error.StillExecuting => {},
            error.NoData => {},
            else => {
                std.debug.print("Fetch failed, getting diagnostic records\n", .{});
                const diagnostic_records = try self.statement.getDiagnosticRecords();
                defer {
                    for (diagnostic_records) |*r| r.deinit(self.allocator);
                    self.allocator.free(diagnostic_records);
                }

                for (diagnostic_records) |record| {
                    const sql_state = odbc.Error.OdbcError.fromString(record.sql_state[0..]);
                    if (sql_state) |state| {
                        std.debug.print("Fetch Error: {s} ({s})\n", .{record.sql_state, @tagName(state)});
                    } else |_| {
                        std.debug.print("Fetch Error: {s} (unknown sql_state)\n", .{record.sql_state});
                    }

                    std.debug.print("Error Message: {s}\n", .{record.error_message});
                }

                return err;
            }
        };

        return result_set;
    }

    /// Bind a value to a parameter index on the current statement. Parameter indices start at `1`.
    pub fn addParam(self: *PreparedStatement, index: usize, param: anytype) !void {
        if (index > self.num_params) return error.InvalidParamIndex;

        const param_index = self.param_data.items.len;
        if (comptime std.meta.trait.isZigString(@TypeOf(param))) {
            try self.param_data.appendSlice(self.allocator, param);
            self.param_indicators[index - 1] = @intCast(c_longlong, param.len);
        } else {
            const ParamType = EraseComptime(@TypeOf(param));
            try self.param_data.appendSlice(self.allocator, std.mem.toBytes(@as(ParamType, param))[0..]);
            self.param_indicators[index - 1] = @sizeOf(ParamType);
        }
        
        const param_ptr = &self.param_data.items[param_index];
        const sql_param = sql_parameter.default(param);

        try self.statement.bindParameter(
            @intCast(u16, index),
            .Input,
            sql_param.c_type,
            sql_param.sql_type,
            @ptrCast(*c_void, param_ptr),
            sql_param.precision,
            &self.param_indicators[index - 1]
        );
    }

    pub fn addParams(self: *PreparedStatement, params: anytype) !void {
        inline for (params) |p| try self.addParam(p[0], p[1]);
    }

    /// Close any open cursor on this statement. If no cursor is open, do nothing.
    pub fn close(self: *PreparedStatement) !void {
        self.statement.closeCursor() catch |err| {
            var error_buf: [@sizeOf(odbc.Error.SqlState) * 2]u8 = undefined;
            var fba = std.heap.FixedBufferAllocator.init(error_buf[0..]);
            var errors = try self.statement.getErrors(&fba.allocator);
            for (errors) |e| {
                // InvalidCursorState just means that no cursor was open on the statement. Here, we just want to
                // ignore this error and pretend everything succeeded.
                if (e == .InvalidCursorState) return;
            }
            return err;
        };
    }

};
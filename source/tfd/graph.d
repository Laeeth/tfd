/// TF_Graph wrapper.
module tfd.graph;

import std.string : fromStringz;

import mir.rc.slim_ptr : createSlimRC, SlimRCPtr;

import tfd.c_api;
import tfd.testing : assertStatus;


/// Creates a new placeholder in a given graph.
@nogc nothrow @trusted
TF_Operation* Placeholder(size_t N = 0)(
    TF_Graph* graph,
    TF_Status* s,
    const(char)* name = "feed",
    TF_DataType dtype = TF_INT32,
    long[N] dims = (long[N]).init)
{
  TF_Operation* op;
  TF_OperationDescription* desc = TF_NewOperation(graph, "Placeholder", name);
  TF_SetAttrType(desc, "dtype", dtype);
  static if (N != 0)
  {
    TF_SetAttrShape(desc, "shape", dims.ptr, dims.length);
  }
  op = TF_FinishOperation(desc, s);
  assertStatus(s);
  assert(op);
  return op;
}


/++ TODO(karita): use pbd instead of protobuf-c
alias AttrValue = Tensorflow__AttrValue;


/// Gets an AttrValue from a given operation.
@nogc nothrow @trusted
bool GetAttrValue(
    TF_Operation* oper, const(char)* attr_name,
    AttrValue* attr_value, TF_Status* s)
{
  TF_Buffer* buffer = TF_NewBuffer();
  scope (exit) TF_DeleteBuffer(buffer);

  TF_OperationGetAttrValueProto(oper, attr_name, buffer, s);
  bool ret = TF_GetCode(s) == TF_OK;
  if (ret)
  {
    auto unpacked = tensorflow__attr_value__unpack(
        null,
        buffer.length,
        cast(const(ubyte)*) buffer.data);
    ret = (unpacked !is null);
    if (ret) *attr_value = *unpacked;
  }
  return ret;
}
+/

/// Creates a const tensor.
@nogc nothrow @trusted
TF_Operation* Const(
    TF_Tensor* t,
    TF_Graph* graph,
    TF_Status* s,
    const(char)* name = "const")
{
  TF_Operation* op;
  TF_OperationDescription* desc = TF_NewOperation(graph, "Const", name);
  TF_SetAttrTensor(desc, "value", t, s);
  TF_SetAttrType(desc, "dtype", TF_TensorType(t));
  op = TF_FinishOperation(desc, s);
  assertStatus(s);
  assert(op !is null);
  return op;
}


/// Creates a scalar const tensor.
@nogc nothrow @trusted
TF_Operation* ScalarConst(int v, TF_Graph* graph, TF_Status* s,
                          const(char)* name = "scalar") 
{
  import tfd.tensor : makeTF_Tensor;
  // TODO(karita): free this tensor
  return Const(makeTF_Tensor(v), graph, s, name);
}


/// Adds two tensors.
@nogc nothrow @trusted
TF_Operation* Add(TF_Operation* l, TF_Operation* r, TF_Graph* graph,
                  TF_Status* s, const(char)* name = "add") {
  TF_OperationDescription* desc = TF_NewOperation(graph, "AddN", name);
  TF_Output[2] inputs;
  inputs[0] = TF_Output(l, 0);
  inputs[1] = TF_Output(r, 0);
  TF_AddInputList(desc, inputs.ptr, 2);
  TF_Operation* op = TF_FinishOperation(desc, s);
  assertStatus(s);
  assert(op !is null);
  return op;
}


/// CAPI Graph test in `tensorflow/c/c_api_test.c`
@nogc nothrow
unittest
{
  TF_Status* s = TF_NewStatus();
  TF_Graph* graph = TF_NewGraph();

  // Make a placeholder operation.
  TF_Operation* feed = Placeholder(graph, s);
  assertStatus(s);

  // Test TF_Operation*() query functions.
  assert(TF_OperationName(feed).fromStringz == "feed");
  assert(TF_OperationOpType(feed).fromStringz == "Placeholder");
  assert(TF_OperationDevice(feed).fromStringz == "");
  assert(TF_OperationNumOutputs(feed) == 1);
  assert(TF_OperationOutputType(TF_Output(feed, 0)) == TF_INT32);
  assert(TF_OperationOutputListLength(feed, "output", s) == 1);
  assertStatus(s);
  assert(TF_OperationNumInputs(feed) == 0);
  assert(TF_OperationOutputNumConsumers(TF_Output(feed, 0)) == 0);
  assert(TF_OperationNumControlInputs(feed) == 0);
  assert(TF_OperationNumControlOutputs(feed) == 0);

  // TODO(karita): implement AttrValue type switching by `value_case`
  // AttrValue attrValue;
  // assert(GetAttrValue(feed, "dtype", &attrValue, s));
  // assert(attrValue.type == TENSORFLOW__DATA_TYPE__DT_INT32);

  // Test not found errors in TF_Operation*() query functions.
  assert(TF_OperationOutputListLength(feed, "bogus", s) == -1);
  assert(TF_GetCode(s) == TF_INVALID_ARGUMENT);
  // assert(!GetAttrValue(feed, "missing", &attrValue, s));
  // assert(TF_Message(s).fromStringz ==
  //        "Operation 'feed' has no attr named 'missing'.");

  // Make a constant oper with the scalar "3".
  TF_Operation* three = ScalarConst(3, graph, s);
  assertStatus(s);
  // Add oper.
  Add(feed, three, graph, s);
  assertStatus(s);
}


/// TF_Graph freed by dtor (RAII) with convinient methods.
struct GraphOwner
{
  /// Raw pointer.
  TF_Graph* ptr;
  /// Status pointer.
  TF_Status* status;
  alias ptr this;

  // Not copyable.
  @disable this(this);

  @nogc nothrow @trusted
  ~this()
  {
    TF_DeleteGraph(this.ptr);
    TF_DeleteStatus(this.status);
  }

  /// Loads serialized graph (GraphDef proto).
  @nogc nothrow @trusted
  void load(const(void)[] proto)
  {
    auto buffer = TF_NewBufferFromString(proto.ptr, proto.length);
    auto opts = TF_NewImportGraphDefOptions;
    TF_GraphImportGraphDef(this.ptr, buffer, opts, this.status);
    assertStatus(this.status);
  }

  /// Returns serialized bytes (GraphDef proto).
  @nogc nothrow @trusted
  TF_Buffer* serialize()
  {
    auto buffer = TF_NewBuffer;
    TF_GraphToGraphDef(this.ptr, buffer, this.status);
    assertStatus(this.status);
    return buffer;
  }

  /// Writes serialized bytes (GraphDef proto) to a given file.
  @nogc nothrow @trusted
  void write(const(char)* fileName)
  {
    import core.stdc.stdio;

    auto buffer = this.serialize();
    auto fp = fopen(fileName, "wb");
    fwrite(buffer.data, 1, buffer.length, fp); 
  }
}

/// TF_Operation wrapper used in Graph.
struct Operation
{
  /// Raw pointer.
  TF_Operation* ptr;
  /// Graph scope containing this operation.
  Graph graph;
  alias ptr this;

  /// Binary operator for +.
  Operation opBinary(string op : "+")(Operation rhs)
  {
    assert(this.graph == rhs.graph);
    scope (exit) assertStatus(this.graph.status);
    return Operation(Add(this.ptr, rhs.ptr, this.graph.ptr, this.graph.status), this.graph);
  }

}

/// Shared GraphOwner type.
struct Graph
{
  import tfd.session : Session;
  import tfd.tensor : tfType;

  /// Base reference counted pointer.
  SlimRCPtr!GraphOwner base;
  alias base this;
  /// Get an operation by name

  @nogc nothrow @trusted
  Operation operationByName(const(char)* name)
  {
    auto opr = TF_GraphOperationByName(this.ptr, name);
    assert(opr);
    return Operation(opr, this);
  }

  /// Creates a placeholder in this graph.
  Operation placeholder(T, size_t N)(
      const(char)* name,
      long[N] dims...)
  {
    scope (exit) assertStatus(this.status);
    return Operation(Placeholder!N(this.ptr, this.status, name, tfType!T, dims), this);
  }

  /// ditto.
  Operation placeholder(T, size_t N)(long[N] dims ...)
  {
    return placeholder!T("", dims);
  }

  /// Creates a constant in this graph.
  Operation constant(S)(S x, const(char)* name = "const")
  {
    import tfd.tensor : makeTF_Tensor;
    scope (exit) assertStatus(this.status);
    // TODO(karita) free TF_Tensor when this class is freed
    return Operation(Const(x.makeTF_Tensor, this.ptr, this.status, name), this);
  }

  /// Creates a Session in this graph.
  @nogc nothrow
  Session session()
  {
    return Session(this.ptr, this.status);
  }
}

/// Creates a new reference-counted Graph object.
@nogc nothrow @trusted
Graph newGraph()
{
  import mir.rc.slim_ptr : createSlimRC;
  return Graph(createSlimRC!GraphOwner(TF_NewGraph(), TF_NewStatus()));
}

/// Export/import graph.
unittest
{
  import tfd.tensor;

  TF_Buffer* buffer;
  scope (exit) TF_DeleteBuffer(buffer);
  {
    auto graph = newGraph;
    with (graph)
    {
      auto a = placeholder!int("a");
      assert(TF_GraphOperationByName(graph, "a"));
      auto b = constant(3, "b");
      assert(TF_GraphOperationByName(graph, "b"));
      // TODO(karita): provide name "add", identity?
      auto add = a + b;
      assert(TF_GraphOperationByName(graph, "add"));
    }
    buffer = graph.serialize;
    // for coverage
    graph.write("tmp.bin");
  }
  with (newGraph) {
    // Import from the GraphDef (protobuf)
    load(buffer.data[0 .. buffer.length]);
    auto a = operationByName("a");
    auto add = operationByName("add");
    const t = session.run([add], [a: 1.tensor])[0].tensor;
    assert(t.scalar!int == 1 + 3);
  }
}
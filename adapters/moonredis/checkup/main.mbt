// `moon run adapters/moonredis/checkup --target native`
//
// Runs the codec audit against moonbitstack/moonredis and prints the findings.

///|
fn main {
  let cases = @adapter.battery()
  println("# Codec audit: moonbitstack/moonredis (RESP2/RESP3)")
  println("")
  println("> 目标类型：纯编解码器。性质：encode/decode 往返、截断必拒、随机字节不崩、深嵌套不爆栈。")
  println("> 出处：moonbitstack/moonredis（Apache-2.0）。未复制任何代码，只调用公开 API。")
  println("")
  let mut bad = 0
  for c in cases {
    if !c.ok {
      bad = bad + 1
    }
    println("- " + @adapter.describe(c))
  }
  println("")
  if bad == 0 {
    println("**\{cases.length()} 项全部通过，未发现缺陷。**")
  } else {
    println("**\{bad} / \{cases.length()} 项报告风险。**")
  }
}

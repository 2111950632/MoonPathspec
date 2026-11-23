///|
extern "js" fn read_request() -> String =
  #| () => globalThis.__moonpathspecRequest

///|
extern "js" fn write_response(response : String) -> Unit =
  #| value => { globalThis.__moonpathspecResponse = value; }

///|
fn main {
  write_response(@moonpathspec.dispatch(read_request()))
}

//! Generated protobuf messages and their canonical protobuf JSON form.

use prost::{Message, Name};
use prost_reflect::{DescriptorPool, DeserializeOptions, DynamicMessage, SerializeOptions};
use serde_json::Value;
use std::sync::LazyLock;

// Generated code keeps the shape prost gives it.
#[allow(clippy::all)]
pub mod agentvmm {
    pub mod host {
        pub mod v1 {
            include!(concat!(env!("OUT_DIR"), "/agentvmm.host.v1.rs"));
        }
    }
    pub mod remote {
        pub mod v1 {
            include!(concat!(env!("OUT_DIR"), "/agentvmm.remote.v1.rs"));
        }
    }
    pub mod service {
        pub mod v1 {
            include!(concat!(env!("OUT_DIR"), "/agentvmm.service.v1.rs"));
        }
    }
    pub mod trust {
        pub mod v1 {
            include!(concat!(env!("OUT_DIR"), "/agentvmm.trust.v1.rs"));
        }
    }
}

#[allow(clippy::all)]
pub mod google {
    pub mod rpc {
        include!(concat!(env!("OUT_DIR"), "/google.rpc.rs"));
    }
}

pub use agentvmm::{
    host::v1 as host, remote::v1 as remote, service::v1 as service, trust::v1 as trust,
};

static POOL: LazyLock<DescriptorPool> = LazyLock::new(|| {
    DescriptorPool::decode(include_bytes!(concat!(env!("OUT_DIR"), "/descriptors.bin")).as_ref())
        .expect("the descriptor set this crate was built from")
});

#[derive(Debug)]
pub struct JsonError;

fn dynamic<M: Message + Name>(message: &M) -> Result<DynamicMessage, JsonError> {
    let descriptor = POOL.get_message_by_name(&M::full_name()).ok_or(JsonError)?;
    DynamicMessage::decode(descriptor, message.encode_to_vec().as_slice()).map_err(|_| JsonError)
}

/// Canonical protobuf JSON with lowerCamelCase names, as Salix reads it.
pub fn to_json<M: Message + Name>(message: &M) -> Result<Value, JsonError> {
    serialize(message, false)
}

/// Canonical protobuf JSON with the proto field names, as typed operation results use.
pub fn to_proto_name_json<M: Message + Name>(message: &M) -> Result<Value, JsonError> {
    serialize(message, true)
}

fn serialize<M: Message + Name>(message: &M, proto_names: bool) -> Result<Value, JsonError> {
    let options = SerializeOptions::new().use_proto_field_name(proto_names);
    dynamic(message)?
        .serialize_with_options(serde_json::value::Serializer, &options)
        .map_err(|_| JsonError)
}

/// Decodes canonical protobuf JSON. Unknown fields are refused.
pub fn from_json<M: Message + Name + Default>(value: &Value) -> Result<M, JsonError> {
    let descriptor = POOL.get_message_by_name(&M::full_name()).ok_or(JsonError)?;
    let message =
        DynamicMessage::deserialize_with_options(descriptor, value, &DeserializeOptions::new())
            .map_err(|_| JsonError)?;
    message.transcode_to::<M>().map_err(|_| JsonError)
}

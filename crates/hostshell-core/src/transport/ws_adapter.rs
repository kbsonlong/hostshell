use std::io;
use std::pin::Pin;
use std::task::{Context, Poll};
use futures_util::{Sink, Stream};
use tokio::io::{AsyncRead, AsyncWrite, ReadBuf};
use tokio_tungstenite::tungstenite::Message;

pub struct WsStreamAdapter<S> {
    inner: S,
    read_buf: Vec<u8>,
    read_pos: usize,
    write_buf: Option<Vec<u8>>,
}

impl<S> WsStreamAdapter<S> {
    pub fn new(inner: S) -> Self {
        Self {
            inner,
            read_buf: Vec::new(),
            read_pos: 0,
            write_buf: None,
        }
    }
}

impl<S> AsyncRead for WsStreamAdapter<S>
where
    S: Stream<Item = std::result::Result<Message, tokio_tungstenite::tungstenite::Error>> + Unpin,
{
    fn poll_read(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &mut ReadBuf<'_>,
    ) -> Poll<io::Result<()>> {
        loop {
            if self.read_pos < self.read_buf.len() {
                let available = self.read_buf.len() - self.read_pos;
                let to_read = available.min(buf.remaining());
                buf.put_slice(&self.read_buf[self.read_pos..self.read_pos + to_read]);
                self.read_pos += to_read;
                if self.read_pos >= self.read_buf.len() {
                    self.read_buf.clear();
                    self.read_pos = 0;
                }
                return Poll::Ready(Ok(()));
            }

            match Pin::new(&mut self.inner).poll_next(cx) {
                Poll::Ready(Some(Ok(msg))) => match msg {
                    Message::Binary(bin) => {
                        if !bin.is_empty() {
                            self.read_buf = bin.to_vec();
                            self.read_pos = 0;
                        }
                    }
                    Message::Close(_) => {
                        return Poll::Ready(Ok(()));
                    }
                    Message::Ping(_) | Message::Pong(_) => {
                        continue;
                    }
                    Message::Text(txt) => {
                        let bytes = txt.as_bytes().to_vec();
                        if !bytes.is_empty() {
                            self.read_buf = bytes;
                            self.read_pos = 0;
                        }
                    }
                    _ => {}
                },
                Poll::Ready(Some(Err(e))) => {
                    return Poll::Ready(Err(io::Error::new(io::ErrorKind::ConnectionReset, e)));
                }
                Poll::Ready(None) => {
                    return Poll::Ready(Ok(()));
                }
                Poll::Pending => {
                    return Poll::Pending;
                }
            }
        }
    }
}

impl<S> AsyncWrite for WsStreamAdapter<S>
where
    S: Sink<Message, Error = tokio_tungstenite::tungstenite::Error> + Unpin,
{
    fn poll_write(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &[u8],
    ) -> Poll<io::Result<usize>> {
        if let Some(pending) = self.write_buf.take() {
            match Pin::new(&mut self.inner).poll_ready(cx) {
                Poll::Ready(Ok(())) => {
                    if let Err(e) = Pin::new(&mut self.inner).start_send(Message::Binary(pending.into())) {
                        return Poll::Ready(Err(io::Error::new(io::ErrorKind::BrokenPipe, e)));
                    }
                }
                Poll::Ready(Err(e)) => {
                    return Poll::Ready(Err(io::Error::new(io::ErrorKind::BrokenPipe, e)));
                }
                Poll::Pending => {
                    self.write_buf = Some(pending);
                    return Poll::Pending;
                }
            }
        }

        match Pin::new(&mut self.inner).poll_ready(cx) {
            Poll::Ready(Ok(())) => {
                let msg = Message::Binary(buf.to_vec().into());
                if let Err(e) = Pin::new(&mut self.inner).start_send(msg) {
                    return Poll::Ready(Err(io::Error::new(io::ErrorKind::BrokenPipe, e)));
                }
                Poll::Ready(Ok(buf.len()))
            }
            Poll::Ready(Err(e)) => Poll::Ready(Err(io::Error::new(io::ErrorKind::BrokenPipe, e))),
            Poll::Pending => {
                self.write_buf = Some(buf.to_vec());
                Poll::Ready(Ok(buf.len()))
            }
        }
    }

    fn poll_flush(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        if let Some(pending) = self.write_buf.take() {
            match Pin::new(&mut self.inner).poll_ready(cx) {
                Poll::Ready(Ok(())) => {
                    if let Err(e) = Pin::new(&mut self.inner).start_send(Message::Binary(pending.into())) {
                        return Poll::Ready(Err(io::Error::new(io::ErrorKind::BrokenPipe, e)));
                    }
                }
                Poll::Ready(Err(e)) => {
                    return Poll::Ready(Err(io::Error::new(io::ErrorKind::BrokenPipe, e)));
                }
                Poll::Pending => {
                    self.write_buf = Some(pending);
                    return Poll::Pending;
                }
            }
        }
        Pin::new(&mut self.inner)
            .poll_flush(cx)
            .map_err(|e| io::Error::new(io::ErrorKind::Other, e))
    }

    fn poll_shutdown(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        let _ = Pin::new(&mut self.inner).start_send(Message::Close(None));
        Pin::new(&mut self.inner)
            .poll_close(cx)
            .map_err(|e| io::Error::new(io::ErrorKind::Other, e))
    }
}
